// ./tools/m8_video_backend/bakeoff.cc
//
// M8 persistent video-backend bakeoff.
//
// This is deliberately not product code. It gives MLT and direct FFmpeg the
// same long-GOP media, keeps one decoder open per clip, asks for the same frame
// sequence, validates an embedded binary frame marker, and measures request
// latency. R3nder's ProjectClock is not involved: neither backend is allowed to
// own project time.

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

extern "C" {
#include <framework/mlt.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/pixfmt.h>
#include <libavutil/rational.h>
}

namespace {

constexpr int kWidth = 1280;
constexpr int kHeight = 720;
constexpr int kFps = 30;
constexpr int kMarkerBits = 10;
constexpr int kMarkerSourceY = 20;
constexpr int kMaxRequestFrame = 559;

std::string ffError(int code) {
  char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
  av_strerror(code, buffer, sizeof(buffer));
  return std::string(buffer);
}

int markerFromYPlane(
    const std::uint8_t* yPlane,
    int stride,
    int width,
    int height) {
  if (yPlane == nullptr || stride <= 0 || width <= 0 || height <= 0) {
    throw std::runtime_error("Invalid Y plane supplied to frame marker reader.");
  }

  int marker = 0;
  for (int bit = 0; bit < kMarkerBits; ++bit) {
    const int sourceX = 20 + bit * 32;
    int x = sourceX * width / kWidth;
    int y = kMarkerSourceY * height / kHeight;
    x = std::clamp(x, 0, width - 1);
    y = std::clamp(y, 0, height - 1);
    if (yPlane[y * stride + x] > 128) {
      marker |= (1 << bit);
    }
  }
  return marker;
}

void warmFileCache(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("Could not open reference media: " + path);
  }

  std::vector<char> buffer(4 * 1024 * 1024);
  while (input) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
  }
}

class Decoder {
 public:
  virtual ~Decoder() = default;
  virtual int markerAt(int targetFrame) = 0;
};

class FfmpegDecoder final : public Decoder {
 public:
  explicit FfmpegDecoder(const std::string& path) {
    int error = avformat_open_input(&format_, path.c_str(), nullptr, nullptr);
    if (error < 0) {
      throw std::runtime_error("FFmpeg open failed: " + ffError(error));
    }

    error = avformat_find_stream_info(format_, nullptr);
    if (error < 0) {
      throw std::runtime_error("FFmpeg stream probe failed: " + ffError(error));
    }

    videoStreamIndex_ =
        av_find_best_stream(format_, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (videoStreamIndex_ < 0) {
      throw std::runtime_error(
          "FFmpeg could not find a video stream: " + ffError(videoStreamIndex_));
    }

    stream_ = format_->streams[videoStreamIndex_];
    const AVCodec* codec = avcodec_find_decoder(stream_->codecpar->codec_id);
    if (codec == nullptr) {
      throw std::runtime_error("FFmpeg could not find the video decoder.");
    }

    codec_ = avcodec_alloc_context3(codec);
    if (codec_ == nullptr) {
      throw std::runtime_error("FFmpeg decoder allocation failed.");
    }

    error = avcodec_parameters_to_context(codec_, stream_->codecpar);
    if (error < 0) {
      throw std::runtime_error(
          "FFmpeg decoder parameter copy failed: " + ffError(error));
    }

    error = avcodec_open2(codec_, codec, nullptr);
    if (error < 0) {
      throw std::runtime_error("FFmpeg decoder open failed: " + ffError(error));
    }

    frame_ = av_frame_alloc();
    packet_ = av_packet_alloc();
    if (frame_ == nullptr || packet_ == nullptr) {
      throw std::runtime_error("FFmpeg frame or packet allocation failed.");
    }

    frameRate_ = av_guess_frame_rate(format_, stream_, nullptr);
    if (frameRate_.num <= 0 || frameRate_.den <= 0) {
      frameRate_ = stream_->avg_frame_rate;
    }
    if (frameRate_.num != kFps * frameRate_.den) {
      throw std::runtime_error("FFmpeg reference clip is not exactly 30 fps.");
    }
  }

  ~FfmpegDecoder() override {
    av_packet_free(&packet_);
    av_frame_free(&frame_);
    avcodec_free_context(&codec_);
    avformat_close_input(&format_);
  }

  int markerAt(int targetFrame) override {
    const std::int64_t streamStart =
        stream_->start_time == AV_NOPTS_VALUE ? 0 : stream_->start_time;
    const std::int64_t targetTimestamp = streamStart + av_rescale_q(
        targetFrame,
        av_inv_q(frameRate_),
        stream_->time_base);

    int error = av_seek_frame(
        format_,
        videoStreamIndex_,
        targetTimestamp,
        AVSEEK_FLAG_BACKWARD);
    if (error < 0) {
      throw std::runtime_error("FFmpeg seek failed: " + ffError(error));
    }
    avcodec_flush_buffers(codec_);

    while ((error = av_read_frame(format_, packet_)) >= 0) {
      if (packet_->stream_index != videoStreamIndex_) {
        av_packet_unref(packet_);
        continue;
      }

      const int sendResult = avcodec_send_packet(codec_, packet_);
      av_packet_unref(packet_);
      if (sendResult < 0 && sendResult != AVERROR(EAGAIN)) {
        throw std::runtime_error(
            "FFmpeg packet submit failed: " + ffError(sendResult));
      }

      while (true) {
        const int receiveResult = avcodec_receive_frame(codec_, frame_);
        if (receiveResult == AVERROR(EAGAIN) || receiveResult == AVERROR_EOF) {
          break;
        }
        if (receiveResult < 0) {
          throw std::runtime_error(
              "FFmpeg frame decode failed: " + ffError(receiveResult));
        }

        const std::int64_t pts = frame_->best_effort_timestamp;
        if (pts != AV_NOPTS_VALUE && pts >= targetTimestamp) {
          if (frame_->format != AV_PIX_FMT_YUV420P) {
            av_frame_unref(frame_);
            throw std::runtime_error(
                "FFmpeg reference decoder did not return yuv420p.");
          }
          const int marker = markerFromYPlane(
              frame_->data[0],
              frame_->linesize[0],
              frame_->width,
              frame_->height);
          av_frame_unref(frame_);
          return marker;
        }
        av_frame_unref(frame_);
      }
    }

    throw std::runtime_error(
        "FFmpeg reached end of stream before the requested frame.");
  }

 private:
  AVFormatContext* format_ = nullptr;
  AVCodecContext* codec_ = nullptr;
  AVFrame* frame_ = nullptr;
  AVPacket* packet_ = nullptr;
  AVStream* stream_ = nullptr;
  int videoStreamIndex_ = -1;
  AVRational frameRate_ = {0, 1};
};

class MltDecoder final : public Decoder {
 public:
  explicit MltDecoder(const std::string& path) {
    profile_ = mlt_profile_init(nullptr);
    if (profile_ == nullptr) {
      throw std::runtime_error("MLT profile allocation failed.");
    }

    profile_->frame_rate_num = kFps;
    profile_->frame_rate_den = 1;
    profile_->width = kWidth;
    profile_->height = kHeight;
    profile_->progressive = 1;
    profile_->sample_aspect_num = 1;
    profile_->sample_aspect_den = 1;

    // NULL service intentionally uses MLT's loader producer. The loader is the
    // normal MLT entry point and supplies image conversion when requested.
    producer_ = mlt_factory_producer(profile_, nullptr, path.c_str());
    if (producer_ == nullptr) {
      throw std::runtime_error("MLT loader could not open the reference clip.");
    }
    mlt_producer_set_speed(producer_, 0.0);
  }

  ~MltDecoder() override {
    if (producer_ != nullptr) {
      mlt_producer_close(producer_);
    }
    if (profile_ != nullptr) {
      mlt_profile_close(profile_);
    }
  }

  int markerAt(int targetFrame) override {
    if (mlt_producer_seek(producer_, targetFrame) != 0) {
      throw std::runtime_error("MLT seek failed.");
    }

    mlt_frame frame = nullptr;
    if (mlt_service_get_frame(MLT_PRODUCER_SERVICE(producer_), &frame, 0) != 0 ||
        frame == nullptr) {
      throw std::runtime_error("MLT could not produce the requested frame.");
    }

    const mlt_position actualPosition = mlt_frame_get_position(frame);
    mlt_image_format format = mlt_image_yuv420p;
    int width = kWidth;
    int height = kHeight;
    std::uint8_t* image = nullptr;

    const int imageError =
        mlt_frame_get_image(frame, &image, &format, &width, &height, 0);
    if (imageError != 0 || image == nullptr) {
      mlt_frame_close(frame);
      throw std::runtime_error("MLT image decode failed.");
    }
    if (format != mlt_image_yuv420p) {
      mlt_frame_close(frame);
      throw std::runtime_error("MLT did not return requested yuv420p image data.");
    }
    if (actualPosition != targetFrame) {
      mlt_frame_close(frame);
      throw std::runtime_error(
          "MLT returned a frame object at a different timeline position.");
    }

    // MLT's planar 8-bit yuv420p image is tightly packed by plane. The Y plane
    // therefore begins at image and has width bytes per row.
    const int marker = markerFromYPlane(image, width, width, height);
    mlt_frame_close(frame);
    return marker;
  }

 private:
  mlt_profile profile_ = nullptr;
  mlt_producer producer_ = nullptr;
};

struct Request {
  int clipIndex;
  int frame;
};

std::vector<Request> forwardJumps() {
  std::vector<Request> requests;
  for (int i = 0; i < 120; ++i) {
    requests.push_back({0, (i * 73) % (kMaxRequestFrame + 1)});
  }
  std::sort(
      requests.begin(),
      requests.end(),
      [](const Request& a, const Request& b) { return a.frame < b.frame; });
  return requests;
}

std::vector<Request> mixedRandom() {
  std::vector<Request> requests;
  std::uint32_t state = 0x13579bdu;
  for (int i = 0; i < 160; ++i) {
    state = state * 1664525u + 1013904223u;
    requests.push_back(
        {0, static_cast<int>(state % (kMaxRequestFrame + 1))});
  }
  return requests;
}

std::vector<Request> backwardScrub() {
  std::vector<Request> requests;
  for (int frame = 520; frame >= 401; --frame) {
    requests.push_back({0, frame});
  }
  return requests;
}

std::vector<Request> twoClipAlternating() {
  std::vector<Request> requests;
  for (int i = 0; i < 200; ++i) {
    const int clip = i % 2;
    const int frame = (i * 97 + clip * 31) % (kMaxRequestFrame + 1);
    requests.push_back({clip, frame});
  }
  return requests;
}

struct Stats {
  std::string backend;
  std::string workload;
  std::size_t requests = 0;
  std::size_t correct = 0;
  double totalMs = 0.0;
  double medianMs = 0.0;
  double p95Ms = 0.0;
  double maxMs = 0.0;
};

double percentile(std::vector<double> samples, double p) {
  if (samples.empty()) return 0.0;
  std::sort(samples.begin(), samples.end());
  const double raw = p * static_cast<double>(samples.size());
  std::size_t index = static_cast<std::size_t>(std::ceil(raw));
  if (index == 0) index = 1;
  if (index > samples.size()) index = samples.size();
  return samples[index - 1];
}

using DecoderFactory =
    std::function<std::unique_ptr<Decoder>(const std::string& path)>;

Stats runWorkload(
    const std::string& backend,
    const std::string& workload,
    const std::vector<Request>& requests,
    const std::vector<std::string>& paths,
    const DecoderFactory& factory) {
  std::vector<std::unique_ptr<Decoder>> decoders;
  decoders.reserve(paths.size());
  for (const std::string& path : paths) {
    decoders.push_back(factory(path));
  }

  std::vector<double> latencies;
  latencies.reserve(requests.size());
  std::size_t correct = 0;

  for (const Request& request : requests) {
    if (request.clipIndex < 0 ||
        request.clipIndex >= static_cast<int>(decoders.size())) {
      throw std::runtime_error("Workload references an invalid clip index.");
    }

    const auto start = std::chrono::steady_clock::now();
    const int marker = decoders[request.clipIndex]->markerAt(request.frame);
    const auto end = std::chrono::steady_clock::now();
    const double elapsed =
        std::chrono::duration<double, std::milli>(end - start).count();
    latencies.push_back(elapsed);

    const int expected = request.frame & ((1 << kMarkerBits) - 1);
    if (marker == expected) {
      ++correct;
    } else {
      std::cerr << backend << " " << workload << " wrong frame: requested "
                << request.frame << ", marker says " << marker << "\n";
    }
  }

  Stats stats;
  stats.backend = backend;
  stats.workload = workload;
  stats.requests = requests.size();
  stats.correct = correct;
  for (double value : latencies) stats.totalMs += value;
  stats.medianMs = percentile(latencies, 0.50);
  stats.p95Ms = percentile(latencies, 0.95);
  stats.maxMs = latencies.empty()
      ? 0.0
      : *std::max_element(latencies.begin(), latencies.end());
  return stats;
}

void printStats(const std::vector<Stats>& results) {
  std::cout << "\nPersistent decoder results\n";
  std::cout << std::left << std::setw(10) << "backend"
            << std::setw(22) << "workload"
            << std::right << std::setw(10) << "correct"
            << std::setw(12) << "median ms"
            << std::setw(12) << "p95 ms"
            << std::setw(12) << "max ms"
            << std::setw(12) << "total ms" << "\n";

  for (const Stats& stats : results) {
    const std::string correctness =
        std::to_string(stats.correct) + "/" + std::to_string(stats.requests);
    std::cout << std::left << std::setw(10) << stats.backend
              << std::setw(22) << stats.workload
              << std::right << std::setw(10) << correctness
              << std::fixed << std::setprecision(3)
              << std::setw(12) << stats.medianMs
              << std::setw(12) << stats.p95Ms
              << std::setw(12) << stats.maxMs
              << std::setw(12) << stats.totalMs << "\n";
  }
}

void writeCsv(const std::string& path, const std::vector<Stats>& results) {
  std::ofstream output(path);
  if (!output) {
    throw std::runtime_error("Could not write result CSV: " + path);
  }
  output << "backend,workload,requests,correct,total_ms,median_ms,p95_ms,max_ms\n";
  output << std::fixed << std::setprecision(6);
  for (const Stats& stats : results) {
    output << stats.backend << ','
           << stats.workload << ','
           << stats.requests << ','
           << stats.correct << ','
           << stats.totalMs << ','
           << stats.medianMs << ','
           << stats.p95Ms << ','
           << stats.maxMs << '\n';
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3 || argc > 4) {
    std::cerr << "Usage: " << argv[0]
              << " clip_a.mp4 clip_b.mp4 [results.csv]\n";
    return 2;
  }

  const std::vector<std::string> paths = {argv[1], argv[2]};
  const std::string csvPath = argc == 4 ? argv[3] : "m8_results.csv";

  try {
    av_log_set_level(AV_LOG_ERROR);
    warmFileCache(paths[0]);
    warmFileCache(paths[1]);

    mlt_repository repository = mlt_factory_init(nullptr);
    if (repository == nullptr) {
      throw std::runtime_error("MLT factory initialization failed.");
    }

    std::cout << "FFmpeg: " << av_version_info() << "\n";
    std::cout << "MLT: " << mlt_version_get_string() << "\n";
    std::cout << "Reference: 1280x720, 30 fps, H.264 GOP 120\n";

    const std::vector<std::pair<std::string, std::vector<Request>>> workloads = {
        {"forward_jumps", forwardJumps()},
        {"mixed_random", mixedRandom()},
        {"backward_scrub", backwardScrub()},
        {"two_clip_alternating", twoClipAlternating()},
    };

    const DecoderFactory mltFactory = [](const std::string& path) {
      return std::make_unique<MltDecoder>(path);
    };
    const DecoderFactory ffmpegFactory = [](const std::string& path) {
      return std::make_unique<FfmpegDecoder>(path);
    };

    std::vector<Stats> results;
    for (const auto& workload : workloads) {
      results.push_back(runWorkload(
          "MLT", workload.first, workload.second, paths, mltFactory));
      results.push_back(runWorkload(
          "FFmpeg", workload.first, workload.second, paths, ffmpegFactory));
    }

    printStats(results);
    writeCsv(csvPath, results);

    bool allCorrect = true;
    for (const Stats& stats : results) {
      if (stats.correct != stats.requests) {
        allCorrect = false;
      }
    }

    mlt_factory_close();
    std::cout << "\nWrote " << csvPath << "\n";
    if (!allCorrect) {
      std::cerr << "M8 FAIL: at least one backend returned the wrong frame.\n";
      return 3;
    }
    std::cout << "M8 correctness gate: PASS\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "M8 bakeoff error: " << error.what() << "\n";
    mlt_factory_close();
    return 1;
  }
}
