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

  for (int chunk = 0; chunk < 100; ++chunk) {
    for (;;) {
      const int32_t result =
          r3_audio_sink_enqueue(sink, silence.data(), silence.size());
      if (result == 1) {
        accepted_samples += kChunkFrames;
        break;
      }
      if (result < 0) {
        char error[512] = {};
        r3_audio_sink_copy_last_error(sink, error, sizeof(error));
        std::fprintf(stderr, "enqueue failed: %s\n", error);
        r3_audio_sink_destroy(sink);
        return 2;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }

  if (!WaitForSubmitted(sink, accepted_samples)) {
    char error[512] = {};
    r3_audio_sink_copy_last_error(sink, error, sizeof(error));
    std::fprintf(stderr, "submitted counter did not reach target: %s\n", error);
    r3_audio_sink_destroy(sink);
    return 3;
  }

  const R3AudioSinkStats before_flush = *r3_audio_sink_read(sink);
  if (before_flush.submitted_samples != accepted_samples) {
    std::fprintf(stderr, "submitted sample count mismatch.\n");
    r3_audio_sink_destroy(sink);
    return 4;
  }
  if (before_flush.latency_samples < 0 ||
      before_flush.latency_samples > kSampleRate) {
    std::fprintf(stderr, "measured latency outside sanity bound.\n");
    r3_audio_sink_destroy(sink);
    return 5;
  }

  if (r3_audio_sink_flush(sink) != 1) {
    char error[512] = {};
    r3_audio_sink_copy_last_error(sink, error, sizeof(error));
    std::fprintf(stderr, "flush failed: %s\n", error);
    r3_audio_sink_destroy(sink);
    return 6;
  }

  const R3AudioSinkStats after_flush = *r3_audio_sink_read(sink);
  if (after_flush.submitted_samples != before_flush.submitted_samples) {
    std::fprintf(stderr, "flush reset monotonic submitted samples.\n");
    r3_audio_sink_destroy(sink);
    return 7;
  }
  if (after_flush.queued_samples != 0 || after_flush.latency_samples != 0) {
    std::fprintf(stderr, "flush did not clear queued/latency state.\n");
    r3_audio_sink_destroy(sink);
    return 8;
  }

  r3_audio_sink_destroy(sink);
  std::printf("audio_sink_test: PASS\n");
  return 0;
}
