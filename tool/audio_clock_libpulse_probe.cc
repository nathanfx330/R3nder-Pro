// ./tool/audio_clock_libpulse_probe.cc
//
// Standalone diagnostic for the future AUDIO ProjectClock authority.
//
// This bypasses paplay and writes raw PCM through PulseAudio's simple client
// API. Every successful pa_simple_write contributes to a monotonic submitted
// sample-frame count. pa_simple_get_latency() is then used to estimate the
// audible position:
//
//   audible_frames = submitted_frames - measured_latency_frames
//
// The important result is not the absolute startup offset. R3nder can anchor
// ProjectTime when audio authority is engaged. What matters is whether the
// audible estimate stays in a narrow band against CLOCK_MONOTONIC instead of
// showing the large buffering sawtooth observed through paplay stdin.

#include <pulse/error.h>
#include <pulse/sample.h>
#include <pulse/simple.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kSampleRate = 48000;
constexpr uint8_t kChannels = 2;
constexpr int kChunkFrames = 480;  // 10 ms at 48 kHz.
constexpr double kToneHz = 440.0;
constexpr double kToneGain = 0.01;
constexpr double kPi = 3.14159265358979323846;

struct Options {
  int seconds = 20;
  int latency_ms = 50;
  std::string device;
};

bool StartsWith(const std::string& value, const char* prefix) {
  return value.rfind(prefix, 0) == 0;
}

int ParseBoundedInt(const std::string& value, const char* name, int min_value,
                    int max_value) {
  char* end = nullptr;
  const long parsed = std::strtol(value.c_str(), &end, 10);
  if (end == value.c_str() || *end != '\0' || parsed < min_value ||
      parsed > max_value) {
    std::fprintf(stderr, "ERROR: %s must be between %d and %d.\n", name,
                 min_value, max_value);
    std::exit(2);
  }
  return static_cast<int>(parsed);
}

Options ParseOptions(int argc, char** argv) {
  Options out;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (StartsWith(arg, "--seconds=")) {
      out.seconds =
          ParseBoundedInt(arg.substr(10), "--seconds", 3, 600);
    } else if (StartsWith(arg, "--latency-ms=")) {
      out.latency_ms =
          ParseBoundedInt(arg.substr(13), "--latency-ms", 1, 5000);
    } else if (StartsWith(arg, "--device=")) {
      out.device = arg.substr(9);
    } else {
      std::fprintf(stderr, "ERROR: unknown option: %s\n", arg.c_str());
      std::exit(2);
    }
  }
  return out;
}

void PrintStats(const char* label, const std::vector<double>& values) {
  if (values.empty()) {
    std::printf("%s: unavailable\n", label);
    return;
  }

  const auto [min_it, max_it] =
      std::minmax_element(values.begin(), values.end());
  double sum = 0.0;
  for (double value : values) sum += value;
  const double average = sum / static_cast<double>(values.size());

  std::printf("%s average: %.3fms\n", label, average);
  std::printf("%s min/max: %.3f / %.3fms\n", label, *min_it, *max_it);
  std::printf("%s spread: %.3fms\n", label, *max_it - *min_it);
}

}  // namespace

int main(int argc, char** argv) {
  const Options options = ParseOptions(argc, argv);

  const pa_sample_spec spec{
      PA_SAMPLE_S16LE,
      kSampleRate,
      kChannels,
  };

  if (!pa_sample_spec_valid(&spec)) {
    std::fprintf(stderr, "ERROR: invalid PulseAudio sample specification.\n");
    return 2;
  }

  pa_buffer_attr attr{};
  attr.maxlength = std::numeric_limits<uint32_t>::max();
  attr.tlength = pa_usec_to_bytes(
      static_cast<pa_usec_t>(options.latency_ms) * PA_USEC_PER_MSEC, &spec);
  attr.prebuf = std::numeric_limits<uint32_t>::max();
  attr.minreq = std::numeric_limits<uint32_t>::max();
  attr.fragsize = std::numeric_limits<uint32_t>::max();

  int error = 0;
  pa_simple* stream = pa_simple_new(
      nullptr,
      "R3nderAudioClockProbe",
      PA_STREAM_PLAYBACK,
      options.device.empty() ? nullptr : options.device.c_str(),
      "R3nderAudioClockProbe",
      &spec,
      nullptr,
      &attr,
      &error);

  if (stream == nullptr) {
    std::fprintf(stderr, "ERROR: pa_simple_new failed: %s\n",
                 pa_strerror(error));
    return 2;
  }

  std::printf("R3NDER DIRECT LIBPULSE CLOCK PROBE\n");
  std::printf("duration: %ds\n", options.seconds);
  std::printf("format: s16le stereo %u Hz\n", kSampleRate);
  std::printf("device: %s\n",
              options.device.empty() ? "default" : options.device.c_str());
  std::printf("requested latency: %dms\n", options.latency_ms);
  std::printf("chunk: %d frames / %.1fms\n\n", kChunkFrames,
              1000.0 * kChunkFrames / kSampleRate);

  std::vector<int16_t> chunk(kChunkFrames * kChannels);
  std::vector<double> latency_samples;
  std::vector<double> audible_error_samples;

  uint64_t submitted_frames = 0;
  uint64_t tone_frame = 0;

  using Clock = std::chrono::steady_clock;
  const Clock::time_point start = Clock::now();
  double next_report_sec = 1.0;

  while (true) {
    for (int frame = 0; frame < kChunkFrames; ++frame) {
      const double phase =
          2.0 * kPi * kToneHz * static_cast<double>(tone_frame) /
          static_cast<double>(kSampleRate);
      const int16_t sample = static_cast<int16_t>(
          std::sin(phase) * kToneGain * std::numeric_limits<int16_t>::max());
      for (int channel = 0; channel < kChannels; ++channel) {
        chunk[frame * kChannels + channel] = sample;
      }
      ++tone_frame;
    }

    if (pa_simple_write(stream, chunk.data(),
                        chunk.size() * sizeof(int16_t), &error) < 0) {
      std::fprintf(stderr, "ERROR: pa_simple_write failed: %s\n",
                   pa_strerror(error));
      pa_simple_free(stream);
      return 3;
    }
    submitted_frames += kChunkFrames;

    const double wall_sec =
        std::chrono::duration<double>(Clock::now() - start).count();
    if (wall_sec >= options.seconds) break;
    if (wall_sec < next_report_sec) continue;

    const pa_usec_t latency_usec = pa_simple_get_latency(stream, &error);
    if (latency_usec == static_cast<pa_usec_t>(-1)) {
      std::fprintf(stderr, "ERROR: pa_simple_get_latency failed: %s\n",
                   pa_strerror(error));
      pa_simple_free(stream);
      return 4;
    }

    const double latency_ms = static_cast<double>(latency_usec) / 1000.0;
    const double submitted_sec =
        static_cast<double>(submitted_frames) / kSampleRate;
    const double audible_sec =
        submitted_sec - static_cast<double>(latency_usec) / PA_USEC_PER_SEC;
    const double audible_error_ms = (audible_sec - wall_sec) * 1000.0;

    if (wall_sec >= 3.0) {
      latency_samples.push_back(latency_ms);
      audible_error_samples.push_back(audible_error_ms);
    }

    std::printf(
        "t=%.2fs  submitted=%llu  latency=%.3fms  "
        "audible_error=%+.3fms\n",
        wall_sec,
        static_cast<unsigned long long>(submitted_frames),
        latency_ms,
        audible_error_ms);

    while (next_report_sec <= wall_sec) next_report_sec += 1.0;
  }

  const pa_usec_t final_latency_usec = pa_simple_get_latency(stream, &error);
  if (final_latency_usec == static_cast<pa_usec_t>(-1)) {
    std::fprintf(stderr, "ERROR: final pa_simple_get_latency failed: %s\n",
                 pa_strerror(error));
    pa_simple_free(stream);
    return 4;
  }

  // This is a diagnostic run, not content playback. Drop queued tone rather
  // than waiting for the tail to drain after the measurement is complete.
  if (pa_simple_flush(stream, &error) < 0) {
    std::fprintf(stderr, "ERROR: pa_simple_flush failed: %s\n",
                 pa_strerror(error));
    pa_simple_free(stream);
    return 5;
  }
  pa_simple_free(stream);

  std::printf("\nfinal submitted sample frames: %llu\n",
              static_cast<unsigned long long>(submitted_frames));
  std::printf("final measured latency: %.3fms\n",
              static_cast<double>(final_latency_usec) / 1000.0);
  PrintStats("measured latency", latency_samples);
  PrintStats("audible estimate error", audible_error_samples);

  std::printf(
      "\nInterpretation: absolute audible_error includes startup handoff. "
      "The key number is its spread after the first three seconds. A narrow "
      "spread means submitted samples minus measured stream latency behaves "
      "like a usable audible clock.\n");

  return 0;
}
