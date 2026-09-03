// ./linux/runner/audio_sink_test.cc

#include "audio_sink.h"
#include "project_clock.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

namespace {

constexpr int32_t kSampleRate = 48000;
constexpr int32_t kChannels = 2;
constexpr int32_t kChunkFrames = 480;
constexpr int32_t kChunkBytes = kChunkFrames * kChannels * 2;
constexpr int32_t kMonotonic = 0;
constexpr int32_t kScrub = 1;
constexpr int32_t kAudio = 2;

bool EnqueueChunks(void* sink, const std::vector<uint8_t>& bytes, int chunks,
                   int64_t* accepted_samples) {
  for (int chunk = 0; chunk < chunks; ++chunk) {
    for (;;) {
      const int32_t result =
          r3_audio_sink_enqueue(sink, bytes.data(), bytes.size());
      if (result == 1) {
        *accepted_samples += kChunkFrames;
        break;
      }
      if (result < 0) return false;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  return true;
}

bool WaitForSubmitted(void* sink, int64_t target_samples) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(4);
  while (std::chrono::steady_clock::now() < deadline) {
    const R3AudioSinkStats* stats = r3_audio_sink_read(sink);
    if (stats->healthy == 0) return false;
    if (stats->submitted_samples >= target_samples) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return false;
}

bool WaitForDrain(void* sink, int64_t target_samples) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(4);
  while (std::chrono::steady_clock::now() < deadline) {
    const R3AudioSinkStats* stats = r3_audio_sink_read(sink);
    if (stats->healthy == 0) return false;
    if (stats->draining == 0 &&
        stats->submitted_samples == target_samples &&
        stats->queued_samples == 0 && stats->latency_samples == 0) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return false;
}

void PrintSinkError(void* sink, const char* prefix) {
  char error[512] = {};
  r3_audio_sink_copy_last_error(sink, error, sizeof(error));
  std::fprintf(stderr, "%s: %s\n", prefix, error);
}

void DestroyBoth(void* sink, void* clock) {
  r3_audio_sink_destroy(sink);
  r3_clock_destroy(clock);
}

}  // namespace

int main() {
  void* clock = r3_clock_create(30, 1);
  if (clock == nullptr) {
    std::fprintf(stderr, "project clock create failed.\n");
    return 1;
  }

  // Give the audio sink an exact authored anchor to freeze while prefill is
  // building. The production preview reaches the same state at the terminal's
  // first audio-bearing tick.
  r3_clock_seek_scrub(clock, 12, 0, 1);

  void* sink = r3_audio_sink_create(nullptr, kSampleRate, kChannels, 50, 100);
  if (sink == nullptr) {
    char error[512] = {};
    r3_audio_sink_copy_create_error(error, sizeof(error));
    r3_clock_destroy(clock);
    std::printf("audio_sink_test: SKIP (%s)\n", error);
    return 0;
  }

  R3ClockSnapshot clock_state = *r3_clock_read(clock);
  if (clock_state.mode != kScrub || clock_state.frame != 12) {
    std::fprintf(stderr, "audio sink did not hold the authored start point.\n");
    DestroyBoth(sink, clock);
    return 2;
  }

  const std::vector<uint8_t> silence(kChunkBytes, 0);

  // Creating a replacement native stream must invalidate the old sink's clock
  // binding even though both sink objects still point at the same ProjectClock.
  // The old sink may finish a device write, but it must no longer advance or
  // release ProjectClock after the replacement generation has armed.
  void* replacement =
      r3_audio_sink_create(nullptr, kSampleRate, kChannels, 50, 100);
  if (replacement == nullptr) {
    char error[512] = {};
    r3_audio_sink_copy_create_error(error, sizeof(error));
    r3_audio_sink_destroy(sink);
    r3_clock_destroy(clock);
    std::printf("audio_sink_test: SKIP replacement (%s)\n", error);
    return 0;
  }

  int64_t stale_samples = 0;
  if (!EnqueueChunks(sink, silence, 1, &stale_samples) ||
      !WaitForSubmitted(sink, stale_samples)) {
    PrintSinkError(sink, "stale generation write failed");
    r3_audio_sink_destroy(sink);
    DestroyBoth(replacement, clock);
    return 3;
  }
  if (r3_clock_get_played_samples(clock) != 0) {
    std::fprintf(stderr,
                 "superseded sink still advanced ProjectClock samples.\n");
    r3_audio_sink_destroy(sink);
    DestroyBoth(replacement, clock);
    return 4;
  }

  r3_audio_sink_destroy(sink);
  sink = replacement;

  clock_state = *r3_clock_read(clock);
  if (clock_state.mode != kScrub || clock_state.frame != 12) {
    std::fprintf(stderr,
                 "superseded sink release disturbed replacement clock hold.\n");
    DestroyBoth(sink, clock);
    return 5;
  }

  int64_t accepted_samples = 0;

  // One second of silence proves the worker queue is paced by the real device.
  if (!EnqueueChunks(sink, silence, 100, &accepted_samples)) {
    PrintSinkError(sink, "enqueue failed");
    DestroyBoth(sink, clock);
    return 6;
  }
  if (!WaitForSubmitted(sink, accepted_samples)) {
    PrintSinkError(sink, "submitted counter did not reach target");
    DestroyBoth(sink, clock);
    return 7;
  }

  clock_state = *r3_clock_read(clock);
  if (clock_state.mode != kAudio) {
    std::fprintf(stderr, "project clock did not enter AUDIO authority.\n");
    DestroyBoth(sink, clock);
    return 8;
  }
  if (r3_clock_get_played_samples(clock) != accepted_samples) {
    std::fprintf(stderr, "project clock sample counter missed submitted PCM.\n");
    DestroyBoth(sink, clock);
    return 9;
  }

  // Natural EOF is requested without blocking the caller. While the device
  // consumes its tail, latency falls and AUDIO ProjectClock follows it. Once
  // the tail is gone, the sink reanchors the exact final ProjectTime onto
  // CLOCK_MONOTONIC so a longer picture cannot freeze.
  if (r3_audio_sink_request_drain(sink) != 1) {
    PrintSinkError(sink, "drain request failed");
    DestroyBoth(sink, clock);
    return 10;
  }
  if (!WaitForDrain(sink, accepted_samples)) {
    PrintSinkError(sink, "drain did not complete");
    DestroyBoth(sink, clock);
    return 11;
  }

  clock_state = *r3_clock_read(clock);
  if (clock_state.mode != kMonotonic) {
    std::fprintf(stderr, "project clock did not hand back after drain.\n");
    DestroyBoth(sink, clock);
    return 12;
  }
  if (clock_state.frame < 42) {
    std::fprintf(stderr, "drain handoff lost audible project time.\n");
    DestroyBoth(sink, clock);
    return 13;
  }
  if (r3_clock_get_played_samples(clock) != accepted_samples) {
    std::fprintf(stderr, "drain reset cumulative project clock samples.\n");
    DestroyBoth(sink, clock);
    return 14;
  }

  // A drained sink is reusable. Its first new packet captures a fresh origin
  // from the SAME cumulative ProjectClock sample counter, then enters AUDIO
  // again once prefill becomes audible.
  if (!EnqueueChunks(sink, silence, 10, &accepted_samples)) {
    PrintSinkError(sink, "enqueue after drain failed");
    DestroyBoth(sink, clock);
    return 15;
  }
  if (!WaitForSubmitted(sink, accepted_samples)) {
    PrintSinkError(sink, "submitted counter after reuse did not reach target");
    DestroyBoth(sink, clock);
    return 16;
  }

  clock_state = *r3_clock_read(clock);
  if (clock_state.mode != kAudio) {
    std::fprintf(stderr, "reused sink did not re-enter AUDIO authority.\n");
    DestroyBoth(sink, clock);
    return 17;
  }
  if (r3_clock_get_played_samples(clock) != accepted_samples) {
    std::fprintf(stderr, "reused sink reset cumulative project clock samples.\n");
    DestroyBoth(sink, clock);
    return 18;
  }

  const R3AudioSinkStats before_flush = *r3_audio_sink_read(sink);
  if (before_flush.submitted_samples != accepted_samples) {
    std::fprintf(stderr, "submitted sample count mismatch.\n");
    DestroyBoth(sink, clock);
    return 19;
  }
  if (before_flush.latency_samples < 0 ||
      before_flush.latency_samples > kSampleRate) {
    std::fprintf(stderr, "measured latency outside sanity bound.\n");
    DestroyBoth(sink, clock);
    return 20;
  }

#ifdef R3_AUDIO_SINK_EXPECT_FLUSH_TIMEOUT
  const auto flush_started = std::chrono::steady_clock::now();
  if (r3_audio_sink_flush(sink) != -1) {
    std::fprintf(stderr, "fault-injected flush did not time out.\n");
    DestroyBoth(sink, clock);
    return 21;
  }
  const auto flush_elapsed = std::chrono::steady_clock::now() - flush_started;
  if (flush_elapsed > std::chrono::milliseconds(250)) {
    std::fprintf(stderr, "flush timeout did not bound the caller wait.\n");
    DestroyBoth(sink, clock);
    return 22;
  }

  char timeout_error[512] = {};
  r3_audio_sink_copy_last_error(sink, timeout_error, sizeof(timeout_error));
  if (std::strstr(timeout_error, "timed out") == nullptr) {
    std::fprintf(stderr, "flush timeout did not report a useful error.\n");
    DestroyBoth(sink, clock);
    return 23;
  }

  // The worker is intentionally still finishing the injected stall. Destroy
  // may wait for it here; M3.1.4b separately hardens that join path.
  DestroyBoth(sink, clock);
  std::printf("audio_sink_test: PASS flush timeout\n");
  return 0;
#else
  if (r3_audio_sink_flush(sink) != 1) {
    PrintSinkError(sink, "flush failed");
    DestroyBoth(sink, clock);
    return 21;
  }

  const R3AudioSinkStats after_flush = *r3_audio_sink_read(sink);
  if (after_flush.submitted_samples != before_flush.submitted_samples) {
    std::fprintf(stderr, "flush reset monotonic submitted samples.\n");
    DestroyBoth(sink, clock);
    return 22;
  }
  if (after_flush.queued_samples != 0 || after_flush.latency_samples != 0 ||
      after_flush.draining != 0) {
    std::fprintf(stderr, "flush did not clear queued/latency/drain state.\n");
    DestroyBoth(sink, clock);
    return 23;
  }

  clock_state = *r3_clock_read(clock);
  if (clock_state.mode != kMonotonic) {
    std::fprintf(stderr, "flush did not hand ProjectClock back to monotonic.\n");
    DestroyBoth(sink, clock);
    return 24;
  }
  if (r3_clock_get_played_samples(clock) != accepted_samples) {
    std::fprintf(stderr, "flush reset ProjectClock cumulative samples.\n");
    DestroyBoth(sink, clock);
    return 25;
  }

  DestroyBoth(sink, clock);
  std::printf("audio_sink_test: PASS\n");
  return 0;
#endif
}
