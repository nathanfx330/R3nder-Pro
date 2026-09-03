// ./linux/runner/audio_sink.cc

#include "audio_sink.h"
#include "project_clock.h"

#include <pulse/error.h>
#include <pulse/sample.h>
#include <pulse/simple.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr int64_t kUsecPerSecond = 1000000LL;
constexpr auto kDrainPollInterval = std::chrono::milliseconds(2);
constexpr auto kDrainPollTimeout = std::chrono::seconds(2);

thread_local std::string g_create_error;

// Each native sink object is one ProjectClock binding generation. Creating a
// newer sink permanently supersedes every older sink, even though all of them
// point at the same long-lived ProjectClock. This is deliberately independent
// of the Dart playback generation: the native worker must be able to reject a
// stale release or sample write without asking Dart whether it is still current.
std::atomic<uint64_t> g_clock_binding_generation{0};

struct AudioSinkState {
  pa_simple* stream = nullptr;
  int32_t sample_rate = 0;
  int32_t channels = 0;
  int32_t bytes_per_frame = 0;
  int64_t max_queue_bytes = 0;

  std::mutex mutex;
  std::condition_variable cv;
  std::deque<std::vector<uint8_t>> queue;
  int64_t queued_bytes = 0;
  bool closing = false;
  bool failed = false;
  uint64_t drain_request = 0;
  uint64_t drain_complete = 0;
  uint64_t flush_request = 0;
  uint64_t flush_complete = 0;
  std::string last_error;

  std::thread worker;

  std::atomic<int64_t> submitted_samples{0};
  std::atomic<int64_t> latency_samples{0};
  std::atomic<int64_t> queued_samples{0};

  // ProjectClock binding. The sink object is short lived, but ProjectClock's
  // played_samples counter is cumulative for the lifetime of the preview
  // clock. Each sink generation captures that cumulative value as its origin.
  // clock_generation is fixed for the lifetime of this sink object; a drained
  // current sink may re-arm, but creation of any newer sink invalidates this
  // generation permanently.
  uint64_t clock_generation = 0;
  void* clock_handle = nullptr;
  R3ClockSnapshot clock_anchor{0, 0, 1, 0, 0, 0};
  int64_t clock_origin_sample = 0;
  bool clock_armed = false;
  bool clock_active = false;
};

int64_t UsecToSamples(pa_usec_t usec, int32_t sample_rate) {
  const __int128 scaled =
      static_cast<__int128>(usec) * static_cast<__int128>(sample_rate);
  return static_cast<int64_t>((scaled + kUsecPerSecond / 2) /
                              kUsecPerSecond);
}

bool ClockStillBound(const AudioSinkState* state) {
  return state->clock_handle != nullptr && state->clock_generation != 0 &&
         g_clock_binding_generation.load(std::memory_order_acquire) ==
             state->clock_generation;
}

void ClearClockBinding(AudioSinkState* state) {
  state->clock_handle = nullptr;
  state->clock_origin_sample = 0;
  state->clock_armed = false;
  state->clock_active = false;
}

void ArmProjectClock(AudioSinkState* state) {
  if (state->clock_armed) return;

  // A superseded sink must never steal ProjectClock ownership back merely
  // because a late feeder reaches enqueue after a replacement sink exists.
  if (state->clock_generation == 0 ||
      g_clock_binding_generation.load(std::memory_order_acquire) !=
          state->clock_generation) {
    return;
  }

  void* clock = r3_clock_active_handle();
  if (clock == nullptr) return;

  state->clock_handle = clock;
  state->clock_anchor = *r3_clock_read(clock);
  state->clock_origin_sample = r3_clock_get_played_samples(clock);
  state->clock_armed = true;
  state->clock_active = false;

  // The sink is created at the authored point where preview audio begins.
  // Hold that exact ProjectTime before the libpulse stream is opened, while
  // device setup and initial queue prefill happen behind the same anchor.
  // When the first sample is due to become audible, UpdateProjectClockTiming()
  // releases this same point under AUDIO authority.
  r3_clock_seek_scrub(clock, state->clock_anchor.frame,
                      state->clock_anchor.phase_num,
                      state->clock_anchor.phase_den);
}

void UpdateProjectClockTiming(AudioSinkState* state) {
  if (!state->clock_armed) return;
  if (!ClockStillBound(state)) {
    ClearClockBinding(state);
    return;
  }

  void* clock = state->clock_handle;
  const int64_t latency =
      state->latency_samples.load(std::memory_order_acquire);

  if (state->clock_active) {
    r3_clock_set_latency_samples(clock, latency);
    return;
  }

  const int64_t played = r3_clock_get_played_samples(clock);
  if (played - state->clock_origin_sample < latency) return;

  r3_clock_seek_audio(clock, state->clock_anchor.frame,
                      state->clock_anchor.phase_num,
                      state->clock_anchor.phase_den,
                      state->clock_origin_sample, state->sample_rate, latency);
  state->clock_active = true;
}

void AddProjectClockSamples(AudioSinkState* state, int64_t samples) {
  if (!state->clock_armed) return;
  if (!ClockStillBound(state)) {
    ClearClockBinding(state);
    return;
  }
  r3_clock_add_played_samples(state->clock_handle, samples);
}

void ReleaseProjectClock(AudioSinkState* state, bool complete_audio_tail) {
  if (!state->clock_armed) return;
  if (!ClockStillBound(state)) {
    ClearClockBinding(state);
    return;
  }

  void* clock = state->clock_handle;
  if (state->clock_active) {
    if (complete_audio_tail) {
      state->latency_samples.store(0, std::memory_order_release);
      r3_clock_set_latency_samples(clock, 0);
    }
    const R3ClockSnapshot now = *r3_clock_read(clock);
    r3_clock_seek_monotonic(clock, now.frame, now.phase_num, now.phase_den);
  } else {
    // Stopped before initial prefill ever became audible. The picture was held
    // at this anchor, so release from the same authored point.
    r3_clock_seek_monotonic(clock, state->clock_anchor.frame,
                            state->clock_anchor.phase_num,
                            state->clock_anchor.phase_den);
  }
  ClearClockBinding(state);
}

void SetFailure(AudioSinkState* state, const std::string& message) {
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->failed = true;
    state->last_error = message;
    state->queue.clear();
    state->queued_bytes = 0;
    state->queued_samples.store(0, std::memory_order_release);
  }
  state->cv.notify_all();
}

bool RefreshLatency(AudioSinkState* state) {
  int error = 0;
  const pa_usec_t usec = pa_simple_get_latency(state->stream, &error);
  if (usec == static_cast<pa_usec_t>(-1)) {
    SetFailure(state,
               std::string("pa_simple_get_latency failed: ") +
                   pa_strerror(error));
    return false;
  }
  state->latency_samples.store(
      UsecToSamples(usec, state->sample_rate), std::memory_order_release);
  UpdateProjectClockTiming(state);
  return true;
}

bool DrainWasSuperseded(AudioSinkState* state) {
  std::lock_guard<std::mutex> lock(state->mutex);
  return state->closing ||
         state->flush_request != state->flush_complete;
}

void WorkerMain(AudioSinkState* state) {
  for (;;) {
    std::vector<uint8_t> chunk;
    uint64_t drain_id = 0;
    uint64_t flush_id = 0;

    {
      std::unique_lock<std::mutex> lock(state->mutex);
      state->cv.wait(lock, [&]() {
        return state->closing || state->failed ||
               state->flush_request != state->flush_complete ||
               state->drain_request != state->drain_complete ||
               !state->queue.empty();
      });

      if (state->failed) break;

      // Flush is destructive and therefore outranks everything else.
      if (state->flush_request != state->flush_complete) {
        flush_id = state->flush_request;
        state->queue.clear();
        state->queued_bytes = 0;
        state->queued_samples.store(0, std::memory_order_release);
      } else if (state->closing) {
        break;
      } else if (!state->queue.empty()) {
        // A drain request waits behind every already-accepted PCM packet. That
        // is what makes drain mean audible EOF rather than merely queue EOF.
        chunk = std::move(state->queue.front());
        state->queue.pop_front();
        state->queued_bytes -= static_cast<int64_t>(chunk.size());
        state->queued_samples.store(
            state->queued_bytes / state->bytes_per_frame,
            std::memory_order_release);
      } else if (state->drain_request != state->drain_complete) {
        drain_id = state->drain_request;
      }
    }

    if (flush_id != 0) {
      // Preserve the audible ProjectTime before discarding anything still
      // buffered by the server. A later sink generation can start from that
      // point with a new sample origin.
      RefreshLatency(state);
      ReleaseProjectClock(state, false);

      int error = 0;
      if (pa_simple_flush(state->stream, &error) < 0) {
        SetFailure(state,
                   std::string("pa_simple_flush failed: ") +
                       pa_strerror(error));
        break;
      }
      state->latency_samples.store(0, std::memory_order_release);
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->flush_complete = flush_id;
        // A flush cancels an outstanding natural drain request.
        state->drain_complete = state->drain_request;
      }
      state->cv.notify_all();
      continue;
    }

    if (drain_id != 0) {
      // With no more writes, submitted_samples stops. Keep ProjectClock under
      // AUDIO authority by repeatedly lowering measured latency as the device
      // consumes its tail. This avoids freezing the picture for the final
      // output buffer and then jumping forward at EOF.
      const auto deadline = std::chrono::steady_clock::now() + kDrainPollTimeout;
      bool fallback_to_monotonic = false;
      bool superseded = false;

      for (;;) {
        if (DrainWasSuperseded(state)) {
          superseded = true;
          break;
        }
        if (!RefreshLatency(state)) break;
        if (state->failed) break;

        const int64_t latency =
            state->latency_samples.load(std::memory_order_acquire);
        // One millisecond is below a visible 30 fps frame and prevents a
        // server reporting a tiny fixed floor from holding this loop forever.
        if (latency <= state->sample_rate / 1000) break;

        if (std::chrono::steady_clock::now() >= deadline) {
          // The simple API gives no better tail clock if latency refuses to
          // converge. Preserve the current audible position and let monotonic
          // carry the remainder rather than freezing the preview.
          ReleaseProjectClock(state, false);
          fallback_to_monotonic = true;
          break;
        }
        std::this_thread::sleep_for(kDrainPollInterval);
      }

      if (state->failed) break;
      if (superseded) continue;

      int error = 0;
      if (pa_simple_drain(state->stream, &error) < 0) {
        SetFailure(state,
                   std::string("pa_simple_drain failed: ") +
                       pa_strerror(error));
        break;
      }

      state->latency_samples.store(0, std::memory_order_release);
      if (!fallback_to_monotonic) {
        // A very short stream can finish before initial latency was ever less
        // than submitted audio. Zero latency makes it eligible now, so the
        // final exact sample count still defines the handoff point.
        UpdateProjectClockTiming(state);
        ReleaseProjectClock(state, true);
      }

      {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->drain_complete = drain_id;
      }
      state->cv.notify_all();
      continue;
    }

    if (chunk.empty()) continue;

    int error = 0;
    if (pa_simple_write(state->stream, chunk.data(), chunk.size(), &error) < 0) {
      SetFailure(state,
                 std::string("pa_simple_write failed: ") +
                     pa_strerror(error));
      break;
    }

    const int64_t submitted =
        static_cast<int64_t>(chunk.size()) / state->bytes_per_frame;
    state->submitted_samples.fetch_add(submitted, std::memory_order_acq_rel);
    AddProjectClockSamples(state, submitted);
    if (!RefreshLatency(state)) break;
  }

  // Closing or a native error must never strand ProjectClock in SCRUB/AUDIO.
  // Preserve the last audible position before the final destructive flush.
  ReleaseProjectClock(state, false);
  if (!state->failed && state->stream != nullptr) {
    int error = 0;
    pa_simple_flush(state->stream, &error);
  }
}

int32_t CopyString(const std::string& value, char* buffer, int32_t capacity) {
  const int32_t full_length = static_cast<int32_t>(value.size());
  if (buffer == nullptr || capacity <= 0) return full_length;

  const int32_t copy_length =
      full_length < capacity - 1 ? full_length : capacity - 1;
  if (copy_length > 0) {
    std::memcpy(buffer, value.data(), static_cast<size_t>(copy_length));
  }
  buffer[copy_length] = '\0';
  return full_length;
}

}  // namespace

extern "C" {

void* r3_audio_sink_create(const char* device, int32_t sample_rate,
                           int32_t channels, int32_t latency_ms,
                           int32_t max_queue_ms) {
  g_create_error.clear();

  if (sample_rate <= 0 || channels <= 0 || channels > 8 || latency_ms <= 0 ||
      max_queue_ms <= 0) {
    g_create_error = "Invalid audio sink parameters.";
    return nullptr;
  }

  const pa_sample_spec spec{
      PA_SAMPLE_S16LE,
      static_cast<uint32_t>(sample_rate),
      static_cast<uint8_t>(channels),
  };
  if (!pa_sample_spec_valid(&spec)) {
    g_create_error = "Invalid PulseAudio sample specification.";
    return nullptr;
  }

  pa_buffer_attr attr{};
  attr.maxlength = std::numeric_limits<uint32_t>::max();
  attr.tlength = pa_usec_to_bytes(
      static_cast<pa_usec_t>(latency_ms) * 1000u, &spec);
  attr.prebuf = std::numeric_limits<uint32_t>::max();
  attr.minreq = std::numeric_limits<uint32_t>::max();
  attr.fragsize = std::numeric_limits<uint32_t>::max();

  AudioSinkState* state = new AudioSinkState();
  state->sample_rate = sample_rate;
  state->channels = channels;
  state->bytes_per_frame = channels * static_cast<int32_t>(sizeof(int16_t));
  state->max_queue_bytes =
      static_cast<int64_t>(sample_rate) * state->bytes_per_frame *
      max_queue_ms / 1000;
  if (state->max_queue_bytes < state->bytes_per_frame) {
    state->max_queue_bytes = state->bytes_per_frame;
  }

  // Claim the next binding generation before ProjectClock is held. A newer
  // native sink therefore invalidates every older sink before either stream
  // can update or release the shared clock again.
  state->clock_generation =
      g_clock_binding_generation.fetch_add(1, std::memory_order_acq_rel) + 1;

  // Freeze ProjectTime before libpulse itself opens the device stream. Decoder
  // startup happens later in Dart, so both device creation and decoding are
  // now behind this same exact authored anchor.
  ArmProjectClock(state);

  int error = 0;
  pa_simple* stream = pa_simple_new(
      nullptr,
      "R3nder",
      PA_STREAM_PLAYBACK,
      (device != nullptr && device[0] != '\0') ? device : nullptr,
      "R3nder Preview",
      &spec,
      nullptr,
      &attr,
      &error);
  if (stream == nullptr) {
    ReleaseProjectClock(state, false);
    g_create_error =
        std::string("pa_simple_new failed: ") + pa_strerror(error);
    delete state;
    return nullptr;
  }
  state->stream = stream;

  try {
    state->worker = std::thread(WorkerMain, state);
  } catch (...) {
    ReleaseProjectClock(state, false);
    pa_simple_free(stream);
    delete state;
    g_create_error = "Could not start native audio sink worker thread.";
    return nullptr;
  }

  return state;
}

void r3_audio_sink_destroy(void* handle) {
  AudioSinkState* state = static_cast<AudioSinkState*>(handle);
  if (state == nullptr) return;

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->closing = true;
    state->queue.clear();
    state->queued_bytes = 0;
    state->queued_samples.store(0, std::memory_order_release);
  }
  state->cv.notify_all();

  if (state->worker.joinable()) state->worker.join();
  if (state->stream != nullptr) pa_simple_free(state->stream);
  delete state;
}

int32_t r3_audio_sink_enqueue(void* handle, const uint8_t* data,
                              int64_t byte_count) {
  AudioSinkState* state = static_cast<AudioSinkState*>(handle);
  if (state == nullptr || data == nullptr || byte_count <= 0 ||
      byte_count % state->bytes_per_frame != 0) {
    return -1;
  }

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->closing || state->failed ||
        state->drain_request != state->drain_complete) {
      return -1;
    }
    if (byte_count > state->max_queue_bytes ||
        state->queued_bytes + byte_count > state->max_queue_bytes) {
      return 0;
    }

    // A drained current sink can be reused. ArmProjectClock refuses the call
    // if a newer native sink generation has superseded this object.
    if (!state->clock_armed) ArmProjectClock(state);

    state->queue.emplace_back(data, data + byte_count);
    state->queued_bytes += byte_count;
    state->queued_samples.store(
        state->queued_bytes / state->bytes_per_frame,
        std::memory_order_release);
  }
  state->cv.notify_one();
  return 1;
}

int32_t r3_audio_sink_request_drain(void* handle) {
  AudioSinkState* state = static_cast<AudioSinkState*>(handle);
  if (state == nullptr) return -1;

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->closing || state->failed) return -1;
    if (state->drain_request == state->drain_complete) {
      ++state->drain_request;
    }
  }
  state->cv.notify_all();
  return 1;
}

int32_t r3_audio_sink_flush(void* handle) {
  AudioSinkState* state = static_cast<AudioSinkState*>(handle);
  if (state == nullptr) return -1;

  uint64_t request = 0;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->closing || state->failed) return -1;
    request = ++state->flush_request;
    state->queue.clear();
    state->queued_bytes = 0;
    state->queued_samples.store(0, std::memory_order_release);
  }
  state->cv.notify_all();

  std::unique_lock<std::mutex> lock(state->mutex);
  state->cv.wait(lock, [&]() {
    return state->failed || state->closing || state->flush_complete >= request;
  });
  return (!state->failed && state->flush_complete >= request) ? 1 : -1;
}

const R3AudioSinkStats* r3_audio_sink_read(void* handle) {
  static thread_local R3AudioSinkStats out;
  out = R3AudioSinkStats{0, 0, 0, 0, 0, 0, 0, 0};

  AudioSinkState* state = static_cast<AudioSinkState*>(handle);
  if (state == nullptr) return &out;

  out.submitted_samples =
      state->submitted_samples.load(std::memory_order_acquire);
  out.latency_samples =
      state->latency_samples.load(std::memory_order_acquire);
  out.queued_samples = state->queued_samples.load(std::memory_order_acquire);
  out.sample_rate = state->sample_rate;
  out.channels = state->channels;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    out.healthy = (!state->failed && !state->closing) ? 1 : 0;
    out.draining =
        state->drain_request != state->drain_complete ? 1 : 0;
  }
  return &out;
}

int32_t r3_audio_sink_copy_last_error(void* handle, char* buffer,
                                      int32_t capacity) {
  AudioSinkState* state = static_cast<AudioSinkState*>(handle);
  if (state == nullptr) {
    return CopyString("Invalid audio sink handle.", buffer, capacity);
  }

  std::string value;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    value = state->last_error;
  }
  return CopyString(value, buffer, capacity);
}

int32_t r3_audio_sink_copy_create_error(char* buffer, int32_t capacity) {
  return CopyString(g_create_error, buffer, capacity);
}

}  // extern "C"
