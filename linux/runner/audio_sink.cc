// ./linux/runner/audio_sink.cc

#include "audio_sink.h"

#include <pulse/error.h>
#include <pulse/sample.h>
#include <pulse/simple.h>

#include <atomic>
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

thread_local std::string g_create_error;

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
  uint64_t flush_request = 0;
  uint64_t flush_complete = 0;
  std::string last_error;

  std::thread worker;

  std::atomic<int64_t> submitted_samples{0};
  std::atomic<int64_t> latency_samples{0};
  std::atomic<int64_t> queued_samples{0};
};

int64_t UsecToSamples(pa_usec_t usec, int32_t sample_rate) {
  const __int128 scaled =
      static_cast<__int128>(usec) * static_cast<__int128>(sample_rate);
  return static_cast<int64_t>((scaled + kUsecPerSecond / 2) /
                              kUsecPerSecond);
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

void RefreshLatency(AudioSinkState* state) {
  int error = 0;
  const pa_usec_t usec = pa_simple_get_latency(state->stream, &error);
  if (usec == static_cast<pa_usec_t>(-1)) {
    SetFailure(state,
               std::string("pa_simple_get_latency failed: ") +
                   pa_strerror(error));
    return;
  }
  state->latency_samples.store(
      UsecToSamples(usec, state->sample_rate), std::memory_order_release);
}

void WorkerMain(AudioSinkState* state) {
  for (;;) {
    std::vector<uint8_t> chunk;
    uint64_t flush_id = 0;

    {
      std::unique_lock<std::mutex> lock(state->mutex);
      state->cv.wait(lock, [&]() {
        return state->closing || state->failed ||
               state->flush_request != state->flush_complete ||
               !state->queue.empty();
      });

      if (state->failed) break;

      if (state->flush_request != state->flush_complete) {
        flush_id = state->flush_request;
        state->queue.clear();
        state->queued_bytes = 0;
        state->queued_samples.store(0, std::memory_order_release);
      } else if (state->closing) {
        break;
      } else if (!state->queue.empty()) {
        chunk = std::move(state->queue.front());
        state->queue.pop_front();
        state->queued_bytes -= static_cast<int64_t>(chunk.size());
        state->queued_samples.store(
            state->queued_bytes / state->bytes_per_frame,
            std::memory_order_release);
      }
    }

    if (flush_id != 0) {
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

    state->submitted_samples.fetch_add(
        static_cast<int64_t>(chunk.size()) / state->bytes_per_frame,
        std::memory_order_acq_rel);
    RefreshLatency(state);
  }

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
    g_create_error =
        std::string("pa_simple_new failed: ") + pa_strerror(error);
    return nullptr;
  }

  AudioSinkState* state = new AudioSinkState();
  state->stream = stream;
  state->sample_rate = sample_rate;
  state->channels = channels;
  state->bytes_per_frame = channels * static_cast<int32_t>(sizeof(int16_t));
  state->max_queue_bytes =
      static_cast<int64_t>(sample_rate) * state->bytes_per_frame *
      max_queue_ms / 1000;
  if (state->max_queue_bytes < state->bytes_per_frame) {
    state->max_queue_bytes = state->bytes_per_frame;
  }

  try {
    state->worker = std::thread(WorkerMain, state);
  } catch (...) {
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
    if (state->closing || state->failed) return -1;
    if (byte_count > state->max_queue_bytes ||
        state->queued_bytes + byte_count > state->max_queue_bytes) {
      return 0;
    }

    state->queue.emplace_back(data, data + byte_count);
    state->queued_bytes += byte_count;
    state->queued_samples.store(
        state->queued_bytes / state->bytes_per_frame,
        std::memory_order_release);
  }
  state->cv.notify_one();
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
  out = R3AudioSinkStats{0, 0, 0, 0, 0, 0, 0};

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
