// ./linux/runner/av_lock_probe.cc
//
// Sustained native A/V lock measurement for M4.
//
// This is deliberately a probe, not product transport. It drives the real
// NativeAudioSink and ProjectClock with bounded 10 ms PCM packets, then samples
// the same clock at a 60 Hz presentation cadence. In video mode it also drives
// the persistent MLT decoder with the exact project frame selected by that
// clock. The resulting log separates three questions:
//
//   1. Does AUDIO ProjectClock stay tightly locked to audible sample time over
//      the sustained run?
//   2. Does adding sustained MLT decode load perturb that clock?
//   3. While that clock remains authoritative, what picture misses or holds
//      occur and does every ready frame exactly match the requested frame?
//
// The raw clock witness compares independently sampled ProjectClock and sink
// state. Pulse latency refreshes are discrete, while ProjectClock deliberately
// clamps its audible sample floor so a higher latency measurement can never
// move project time backward. An isolated sample on a latency refresh boundary
// can therefore differ from the raw played-minus-current-latency calculation
// even though there is no sustained drift. Acceptance measures the p95 error,
// the longest >1 ms streak, and a one-project-frame hard transient ceiling.
//
// Picture availability is deliberately not allowed to own time. The decoder
// may miss a presentation poll or leave the previous picture on screen; that
// is diagnostic information, not permission to slow AUDIO ProjectClock. This
// is the architecture M4 is validating. A frame that IS returned ready must
// still be the exact integer frame selected by ProjectClock.
//
// The probe feeds silence. Audible content is irrelevant to the clock and a
// sustained tone would only make a diagnostic run unpleasant.

#include "audio_sink.h"
#include "media_decoder.h"
#include "project_clock.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int64_t kProjectFps = 30;
constexpr int32_t kSampleRate = 48000;
constexpr int32_t kChannels = 2;
constexpr int32_t kBytesPerSample = 2;
constexpr int32_t kPacketFrames = 480;
constexpr int32_t kPacketBytes =
    kPacketFrames * kChannels * kBytesPerSample;
constexpr int32_t kSinkLatencyMs = 50;
constexpr int32_t kSinkQueueMs = 100;
constexpr int32_t kDecodeWidth = 960;
constexpr int32_t kDecodeHeight = 540;
constexpr int32_t kClockAudioMode = 2;
constexpr double kSteadyClockErrorUs = 1000.0;
constexpr double kTransientClockErrorUs =
    1000000.0 / static_cast<double>(kProjectFps);
constexpr int64_t kMaxClockErrorStreak = 1;
constexpr auto kPresentationStep = std::chrono::microseconds(16667);

struct Metrics {
  int64_t samples = 0;
  int64_t audio_samples = 0;
  int64_t video_ready = 0;
  int64_t video_startup_misses = 0;
  int64_t video_poll_misses = 0;
  int64_t video_stale_holds = 0;
  int64_t video_stale_hold_streak = 0;
  int64_t video_stale_hold_streak_max = 0;
  int64_t video_stale_gap_frames_max = 0;
  int64_t video_frame_mismatches = 0;
  int64_t mode_transitions = 0;
  int64_t clock_error_over_1ms_samples = 0;
  int64_t clock_error_over_1ms_streak = 0;
  int64_t clock_error_over_1ms_streak_max = 0;
  int32_t last_mode = -1;
  std::vector<double> clock_abs_error_us;
  std::vector<double> frame_phase_frames;
};

double ExactFrame(const R3ClockSnapshot& snapshot) {
  const double phase = snapshot.phase_den > 0
                           ? static_cast<double>(snapshot.phase_num) /
                                 static_cast<double>(snapshot.phase_den)
                           : 0.0;
  return static_cast<double>(snapshot.frame) + phase;
}

double Percentile(std::vector<double> values, double fraction) {
  if (values.empty()) return 0.0;
  std::sort(values.begin(), values.end());
  const double scaled =
      fraction * static_cast<double>(values.size() - 1);
  const std::size_t lower = static_cast<std::size_t>(std::floor(scaled));
  const std::size_t upper = static_cast<std::size_t>(std::ceil(scaled));
  if (lower == upper) return values[lower];
  const double mix = scaled - static_cast<double>(lower);
  return values[lower] * (1.0 - mix) + values[upper] * mix;
}

double Maximum(const std::vector<double>& values) {
  if (values.empty()) return 0.0;
  return *std::max_element(values.begin(), values.end());
}

std::string AudioSinkError(void* sink) {
  char buffer[1024];
  std::memset(buffer, 0, sizeof(buffer));
  r3_audio_sink_copy_last_error(sink, buffer,
                                static_cast<int32_t>(sizeof(buffer)));
  return std::string(buffer);
}

std::string AudioSinkCreateError() {
  char buffer[1024];
  std::memset(buffer, 0, sizeof(buffer));
  r3_audio_sink_copy_create_error(buffer,
                                  static_cast<int32_t>(sizeof(buffer)));
  return std::string(buffer);
}

std::string MediaDecoderError(void* decoder) {
  char buffer[1024];
  std::memset(buffer, 0, sizeof(buffer));
  r3_media_decoder_copy_last_error(decoder, buffer,
                                   static_cast<int32_t>(sizeof(buffer)));
  return std::string(buffer);
}

std::string MediaDecoderCreateError() {
  char buffer[1024];
  std::memset(buffer, 0, sizeof(buffer));
  r3_media_decoder_copy_create_error(buffer,
                                     static_cast<int32_t>(sizeof(buffer)));
  return std::string(buffer);
}

bool ParseDurationMs(const char* text, int64_t* out) {
  if (text == nullptr || out == nullptr) return false;
  char* end = nullptr;
  const long long value = std::strtoll(text, &end, 10);
  if (end == text || *end != '\0' || value < 1000 || value > 600000) {
    return false;
  }
  *out = static_cast<int64_t>(value);
  return true;
}

void FeedSilence(void* sink, std::atomic<bool>* stop,
                 std::atomic<bool>* failed) {
  const std::vector<uint8_t> packet(static_cast<std::size_t>(kPacketBytes), 0);

  while (!stop->load(std::memory_order_acquire)) {
    const int32_t result =
        r3_audio_sink_enqueue(sink, packet.data(), kPacketBytes);
    if (result > 0) continue;
    if (result == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }

    failed->store(true, std::memory_order_release);
    return;
  }
}

bool DrainSink(void* sink) {
  if (r3_audio_sink_request_drain(sink) < 0) return false;

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(4);
  for (;;) {
    const R3AudioSinkStats stats = *r3_audio_sink_read(sink);
    if (!stats.healthy) return false;
    if (!stats.draining) return true;
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
}

int RunProbe(const std::string& mode, int64_t duration_ms,
             const char* video_path) {
  const bool with_video = mode == "video";

  void* clock = r3_clock_create(kProjectFps, 1);
  if (clock == nullptr) {
    std::cerr << "AV_LOCK_FAIL stage=clock_create\n";
    return 2;
  }
  r3_clock_seek_monotonic(clock, 0, 0, 1);

  void* sink = r3_audio_sink_create(nullptr, kSampleRate, kChannels,
                                    kSinkLatencyMs, kSinkQueueMs);
  if (sink == nullptr) {
    std::cout << "AV_LOCK_SKIP mode=" << mode
              << " reason=audio_sink_create detail=\""
              << AudioSinkCreateError() << "\"\n";
    r3_clock_destroy(clock);
    return 0;
  }

  void* decoder = nullptr;
  int64_t decoder_length = 0;
  if (with_video) {
    decoder = r3_media_decoder_create(video_path);
    if (decoder == nullptr) {
      std::cerr << "AV_LOCK_FAIL stage=decoder_create detail=\""
                << MediaDecoderCreateError() << "\"\n";
      r3_audio_sink_destroy(sink);
      r3_clock_destroy(clock);
      return 3;
    }
    decoder_length = r3_media_decoder_length(decoder);
    if (decoder_length <= 0) {
      std::cerr << "AV_LOCK_FAIL stage=decoder_length value="
                << decoder_length << "\n";
      r3_media_decoder_destroy(decoder);
      r3_audio_sink_destroy(sink);
      r3_clock_destroy(clock);
      return 4;
    }
  }

  std::atomic<bool> stop_feeder{false};
  std::atomic<bool> feeder_failed{false};
  std::thread feeder(FeedSilence, sink, &stop_feeder, &feeder_failed);

  Metrics metrics;
  int64_t presented_frame = -1;
  const auto started = std::chrono::steady_clock::now();
  auto next_sample = started;

  std::cout << "AV_LOCK_BEGIN mode=" << mode
            << " duration_ms=" << duration_ms
            << " project_fps=" << kProjectFps
            << " sample_rate=" << kSampleRate
            << " decode=" << (with_video ? "mlt" : "none")
            << " decode_size=" << (with_video ? "960x540" : "none")
            << "\n";

  bool run_failed = false;
  while (true) {
    const auto now_steady = std::chrono::steady_clock::now();
    const int64_t elapsed_us =
        std::chrono::duration_cast<std::chrono::microseconds>(
            now_steady - started)
            .count();
    if (elapsed_us >= duration_ms * 1000) break;

    if (feeder_failed.load(std::memory_order_acquire)) {
      std::cerr << "AV_LOCK_FAIL stage=audio_feeder detail=\""
                << AudioSinkError(sink) << "\"\n";
      run_failed = true;
      break;
    }

    const R3ClockSnapshot snapshot = *r3_clock_read(clock);
    const R3AudioSinkStats stats = *r3_audio_sink_read(sink);
    const int64_t played_samples = r3_clock_get_played_samples(clock);
    const double exact_frame = ExactFrame(snapshot);

    if (metrics.last_mode >= 0 && snapshot.mode != metrics.last_mode) {
      metrics.mode_transitions += 1;
    }
    metrics.last_mode = snapshot.mode;
    metrics.samples += 1;

    double signed_clock_error_us = 0.0;
    bool has_clock_error = false;
    if (snapshot.mode == kClockAudioMode && stats.sample_rate > 0) {
      const int64_t audible_samples =
          std::max<int64_t>(0, played_samples - stats.latency_samples);
      const double audible_seconds =
          static_cast<double>(audible_samples) /
          static_cast<double>(stats.sample_rate);
      const double clock_seconds =
          exact_frame / static_cast<double>(kProjectFps);
      signed_clock_error_us =
          (clock_seconds - audible_seconds) * 1000000.0;
      const double abs_clock_error_us = std::abs(signed_clock_error_us);
      metrics.clock_abs_error_us.push_back(abs_clock_error_us);
      metrics.audio_samples += 1;
      has_clock_error = true;

      if (abs_clock_error_us > kSteadyClockErrorUs) {
        metrics.clock_error_over_1ms_samples += 1;
        metrics.clock_error_over_1ms_streak += 1;
        metrics.clock_error_over_1ms_streak_max = std::max(
            metrics.clock_error_over_1ms_streak_max,
            metrics.clock_error_over_1ms_streak);
      } else {
        metrics.clock_error_over_1ms_streak = 0;
      }
    } else {
      metrics.clock_error_over_1ms_streak = 0;
    }

    int64_t requested_frame = -1;
    int poll_result = 0;
    double frame_phase_frames = 0.0;
    bool has_frame_phase = false;
    bool stale_hold = false;
    int64_t presented_delta_frames = 0;

    if (with_video) {
      requested_frame = snapshot.frame;
      if (requested_frame < 0) requested_frame = 0;
      if (requested_frame >= decoder_length) {
        requested_frame = decoder_length - 1;
      }

      if (r3_media_decoder_request(decoder, requested_frame, kDecodeWidth,
                                   kDecodeHeight) < 0) {
        std::cerr << "AV_LOCK_FAIL stage=video_request detail=\""
                  << MediaDecoderError(decoder) << "\"\n";
        run_failed = true;
        break;
      }

      R3MediaDecodedFrame frame{};
      poll_result = r3_media_decoder_poll(decoder, requested_frame,
                                          kDecodeWidth, kDecodeHeight, &frame);
      if (poll_result < 0) {
        std::cerr << "AV_LOCK_FAIL stage=video_poll detail=\""
                  << MediaDecoderError(decoder) << "\"\n";
        run_failed = true;
        break;
      }

      if (poll_result > 0) {
        presented_frame = frame.actual_frame;
        if (presented_frame != requested_frame) {
          metrics.video_frame_mismatches += 1;
        }
        r3_media_decoded_frame_release(&frame);
        metrics.video_ready += 1;
        metrics.video_stale_hold_streak = 0;
      } else if (presented_frame < 0) {
        metrics.video_startup_misses += 1;
        metrics.video_stale_hold_streak = 0;
      } else {
        metrics.video_poll_misses += 1;
        presented_delta_frames = requested_frame - presented_frame;
        stale_hold = presented_delta_frames != 0;
        if (stale_hold) {
          metrics.video_stale_holds += 1;
          metrics.video_stale_hold_streak += 1;
          metrics.video_stale_hold_streak_max = std::max(
              metrics.video_stale_hold_streak_max,
              metrics.video_stale_hold_streak);
          metrics.video_stale_gap_frames_max = std::max(
              metrics.video_stale_gap_frames_max,
              std::llabs(presented_delta_frames));
        } else {
          metrics.video_stale_hold_streak = 0;
        }
      }

      if (snapshot.mode == kClockAudioMode &&
          presented_frame == requested_frame) {
        // This is deliberately frame phase, not decoder lag. If exact project
        // time is 231.944 and the requested/presented integer frame is 231,
        // 0.944 means the correct frame is 94.4% through its display interval.
        frame_phase_frames =
            exact_frame - static_cast<double>(requested_frame);
        metrics.frame_phase_frames.push_back(frame_phase_frames);
        has_frame_phase = true;
      }
    }

    std::cout << std::fixed << std::setprecision(3)
              << "SAMPLE mode=" << mode
              << " elapsed_us=" << elapsed_us
              << " clock_mode=" << snapshot.mode
              << " clock_frame=" << snapshot.frame
              << " phase_num=" << snapshot.phase_num
              << " phase_den=" << snapshot.phase_den
              << " exact_frame=" << exact_frame
              << " played_samples=" << played_samples
              << " submitted_samples=" << stats.submitted_samples
              << " latency_samples=" << stats.latency_samples
              << " queued_samples=" << stats.queued_samples
              << " sink_healthy=" << stats.healthy
              << " sink_draining=" << stats.draining;

    if (has_clock_error) {
      std::cout << " clock_error_us=" << signed_clock_error_us;
    } else {
      std::cout << " clock_error_us=na";
    }

    if (with_video) {
      std::cout << " requested_frame=" << requested_frame
                << " poll=" << poll_result
                << " presented_frame=" << presented_frame;
      if (presented_frame >= 0) {
        std::cout << " frame_match="
                  << (presented_frame == requested_frame ? 1 : 0)
                  << " stale_hold=" << (stale_hold ? 1 : 0)
                  << " presented_delta_frames=" << presented_delta_frames;
      } else {
        std::cout << " frame_match=na"
                  << " stale_hold=na"
                  << " presented_delta_frames=na";
      }
      if (has_frame_phase) {
        std::cout << " frame_phase_frames=" << frame_phase_frames;
      } else {
        std::cout << " frame_phase_frames=na";
      }
    }
    std::cout << "\n";

    next_sample += kPresentationStep;
    std::this_thread::sleep_until(next_sample);
  }

  stop_feeder.store(true, std::memory_order_release);
  feeder.join();

  if (!run_failed && feeder_failed.load(std::memory_order_acquire)) {
    std::cerr << "AV_LOCK_FAIL stage=audio_feeder_shutdown detail=\""
              << AudioSinkError(sink) << "\"\n";
    run_failed = true;
  }

  if (!run_failed && !DrainSink(sink)) {
    std::cerr << "AV_LOCK_FAIL stage=audio_drain detail=\""
              << AudioSinkError(sink) << "\"\n";
    run_failed = true;
  }

  const double clock_error_p50 =
      Percentile(metrics.clock_abs_error_us, 0.50);
  const double clock_error_p95 =
      Percentile(metrics.clock_abs_error_us, 0.95);
  const double clock_error_max = Maximum(metrics.clock_abs_error_us);

  std::cout << std::fixed << std::setprecision(3)
            << "SUMMARY mode=" << mode
            << " samples=" << metrics.samples
            << " audio_samples=" << metrics.audio_samples
            << " mode_transitions=" << metrics.mode_transitions
            << " clock_abs_error_us_p50=" << clock_error_p50
            << " clock_abs_error_us_p95=" << clock_error_p95
            << " clock_abs_error_us_max=" << clock_error_max
            << " clock_error_over_1ms_samples="
            << metrics.clock_error_over_1ms_samples
            << " clock_error_over_1ms_streak_max="
            << metrics.clock_error_over_1ms_streak_max
            << " video_ready=" << metrics.video_ready
            << " video_startup_misses=" << metrics.video_startup_misses
            << " video_poll_misses=" << metrics.video_poll_misses
            << " video_stale_holds=" << metrics.video_stale_holds
            << " video_stale_hold_streak_max="
            << metrics.video_stale_hold_streak_max
            << " video_stale_gap_frames_max="
            << metrics.video_stale_gap_frames_max
            << " video_frame_mismatches=" << metrics.video_frame_mismatches
            << " frame_phase_frames_p50="
            << Percentile(metrics.frame_phase_frames, 0.50)
            << " frame_phase_frames_p95="
            << Percentile(metrics.frame_phase_frames, 0.95)
            << " frame_phase_frames_max="
            << Maximum(metrics.frame_phase_frames)
            << "\n";

  if (!run_failed) {
    if (metrics.samples <= 0 || metrics.audio_samples < metrics.samples - 2 ||
        metrics.mode_transitions != 1 ||
        clock_error_p95 > kSteadyClockErrorUs ||
        clock_error_max > kTransientClockErrorUs ||
        metrics.clock_error_over_1ms_streak_max > kMaxClockErrorStreak) {
      std::cerr << "AV_LOCK_FAIL stage=clock_acceptance"
                << " samples=" << metrics.samples
                << " audio_samples=" << metrics.audio_samples
                << " mode_transitions=" << metrics.mode_transitions
                << " clock_abs_error_us_p95=" << clock_error_p95
                << " clock_abs_error_us_max=" << clock_error_max
                << " clock_error_over_1ms_samples="
                << metrics.clock_error_over_1ms_samples
                << " clock_error_over_1ms_streak_max="
                << metrics.clock_error_over_1ms_streak_max << "\n";
      run_failed = true;
    }
  }

  if (!run_failed && with_video) {
    // M4 is a clock-authority test. Picture work may miss or hold without ever
    // slowing AUDIO ProjectClock. Those events remain in the summary so M10
    // presentation/performance work can evaluate them separately. What M4 does
    // require is that decoding is alive and every returned exact frame matches
    // the frame selected by the audio-owned ProjectClock.
    if (metrics.video_ready <= 0 || metrics.video_frame_mismatches != 0) {
      std::cerr << "AV_LOCK_FAIL stage=video_acceptance"
                << " video_ready=" << metrics.video_ready
                << " video_startup_misses=" << metrics.video_startup_misses
                << " video_poll_misses=" << metrics.video_poll_misses
                << " video_stale_holds=" << metrics.video_stale_holds
                << " video_stale_hold_streak_max="
                << metrics.video_stale_hold_streak_max
                << " video_stale_gap_frames_max="
                << metrics.video_stale_gap_frames_max
                << " video_frame_mismatches="
                << metrics.video_frame_mismatches << "\n";
      run_failed = true;
    }
  }

  if (decoder != nullptr) r3_media_decoder_destroy(decoder);
  r3_audio_sink_destroy(sink);
  r3_clock_destroy(clock);

  if (run_failed) return 5;
  std::cout << "AV_LOCK_PASS mode=" << mode << "\n";
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::cerr << "Usage: av_lock_probe baseline <duration_ms>\n"
              << "   or: av_lock_probe video <duration_ms> <clip>\n";
    return 64;
  }

  const std::string mode(argv[1]);
  if (mode != "baseline" && mode != "video") {
    std::cerr << "Unknown mode: " << mode << "\n";
    return 64;
  }

  int64_t duration_ms = 0;
  if (!ParseDurationMs(argv[2], &duration_ms)) {
    std::cerr << "Invalid duration_ms: " << argv[2] << "\n";
    return 64;
  }

  const char* video_path = nullptr;
  if (mode == "video") {
    if (argc < 4 || argv[3] == nullptr || argv[3][0] == '\0') {
      std::cerr << "video mode requires a clip path\n";
      return 64;
    }
    video_path = argv[3];
  }

  return RunProbe(mode, duration_ms, video_path);
}
