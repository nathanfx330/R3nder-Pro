// ./linux/runner/audio_sink_test.cc

#include "audio_sink.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>
#include <vector>

namespace {

constexpr int32_t kSampleRate = 48000;
constexpr int32_t kChannels = 2;
constexpr int32_t kChunkFrames = 480;
constexpr int32_t kChunkBytes = kChunkFrames * kChannels * 2;

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

}  // namespace

int main() {
  void* sink = r3_audio_sink_create(nullptr, kSampleRate, kChannels, 50, 100);
  if (sink == nullptr) {
    char error[512] = {};
    r3_audio_sink_copy_create_error(error, sizeof(error));
    std::printf("audio_sink_test: SKIP (%s)\n", error);
    return 0;
  }

  const std::vector<uint8_t> silence(kChunkBytes, 0);
  int64_t accepted_samples = 0;

  // One second of silence proves the worker queue is paced by the real device.
  if (!EnqueueChunks(sink, silence, 100, &accepted_samples)) {
    PrintSinkError(sink, "enqueue failed");
    r3_audio_sink_destroy(sink);
    return 2;
  }

  // Natural EOF is requested without blocking the caller. The worker submits
  // every accepted packet, performs pa_simple_drain(), and reports completion
  // through the stats snapshot.
  if (r3_audio_sink_request_drain(sink) != 1) {
    PrintSinkError(sink, "drain request failed");
    r3_audio_sink_destroy(sink);
    return 3;
  }
  if (!WaitForDrain(sink, accepted_samples)) {
    PrintSinkError(sink, "drain did not complete");
    r3_audio_sink_destroy(sink);
    return 4;
  }

  // A drained sink is reusable. Submit another short segment, then prove a
  // destructive flush still preserves the monotonic submitted counter.
  if (!EnqueueChunks(sink, silence, 10, &accepted_samples)) {
    PrintSinkError(sink, "enqueue after drain failed");
    r3_audio_sink_destroy(sink);
    return 5;
  }
  if (!WaitForSubmitted(sink, accepted_samples)) {
    PrintSinkError(sink, "submitted counter did not reach target");
    r3_audio_sink_destroy(sink);
    return 6;
  }

  const R3AudioSinkStats before_flush = *r3_audio_sink_read(sink);
  if (before_flush.submitted_samples != accepted_samples) {
    std::fprintf(stderr, "submitted sample count mismatch.\n");
    r3_audio_sink_destroy(sink);
    return 7;
  }
  if (before_flush.latency_samples < 0 ||
      before_flush.latency_samples > kSampleRate) {
    std::fprintf(stderr, "measured latency outside sanity bound.\n");
    r3_audio_sink_destroy(sink);
    return 8;
  }

  if (r3_audio_sink_flush(sink) != 1) {
    PrintSinkError(sink, "flush failed");
    r3_audio_sink_destroy(sink);
    return 9;
  }

  const R3AudioSinkStats after_flush = *r3_audio_sink_read(sink);
  if (after_flush.submitted_samples != before_flush.submitted_samples) {
    std::fprintf(stderr, "flush reset monotonic submitted samples.\n");
    r3_audio_sink_destroy(sink);
    return 10;
  }
  if (after_flush.queued_samples != 0 || after_flush.latency_samples != 0 ||
      after_flush.draining != 0) {
    std::fprintf(stderr, "flush did not clear queued/latency/drain state.\n");
    r3_audio_sink_destroy(sink);
    return 11;
  }

  r3_audio_sink_destroy(sink);
  std::printf("audio_sink_test: PASS\n");
  return 0;
}
