// ./linux/runner/media_decoder_test.cc

#include "media_decoder.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

struct SinkProbe {
  std::atomic<int> calls{0};
  std::atomic<int64_t> requested_frame{-1};
  std::atomic<int64_t> actual_frame{-1};
  std::atomic<int32_t> width{0};
  std::atomic<int32_t> height{0};
  std::atomic<int32_t> stride{0};
  std::atomic<int64_t> byte_length{0};
  std::atomic<int> has_pixels{0};
};

void ProbeSink(
    void* decoder_handle,
    int64_t requested_frame,
    int64_t actual_frame,
    int32_t width,
    int32_t height,
    int32_t stride,
    const uint8_t* rgba,
    int64_t byte_length,
    void* user_data) {
  (void)decoder_handle;
  SinkProbe* probe = static_cast<SinkProbe*>(user_data);
  if (probe == nullptr) return;

  probe->requested_frame.store(requested_frame, std::memory_order_relaxed);
  probe->actual_frame.store(actual_frame, std::memory_order_relaxed);
  probe->width.store(width, std::memory_order_relaxed);
  probe->height.store(height, std::memory_order_relaxed);
  probe->stride.store(stride, std::memory_order_relaxed);
  probe->byte_length.store(byte_length, std::memory_order_relaxed);
  probe->has_pixels.store(rgba != nullptr ? 1 : 0, std::memory_order_relaxed);
  probe->calls.fetch_add(1, std::memory_order_release);
}

std::string DecoderError(void* handle) {
  char buffer[1024] = {};
  r3_media_decoder_copy_last_error(handle, buffer, sizeof(buffer));
  return std::string(buffer);
}

std::string CreateError() {
  char buffer[1024] = {};
  r3_media_decoder_copy_create_error(buffer, sizeof(buffer));
  return std::string(buffer);
}

bool ValidateFrame(R3MediaDecodedFrame* frame, int64_t source_frame) {
  bool ok = true;
  if (frame->requested_frame != source_frame) {
    std::cerr << "requested frame mismatch: expected " << source_frame
              << ", got " << frame->requested_frame << "\n";
    ok = false;
  }
  if (frame->actual_frame != source_frame) {
    std::cerr << "actual frame mismatch: requested " << source_frame
              << ", actual " << frame->actual_frame << "\n";
    ok = false;
  }
  if (frame->width != 320 || frame->height != 180) {
    std::cerr << "decoded size mismatch: " << frame->width << "x"
              << frame->height << "\n";
    ok = false;
  }
  if (frame->stride != frame->width * 4) {
    std::cerr << "RGBA stride mismatch\n";
    ok = false;
  }
  const int64_t expected_bytes =
      static_cast<int64_t>(frame->width) * frame->height * 4;
  if (frame->byte_length != expected_bytes || frame->rgba == nullptr) {
    std::cerr << "RGBA buffer mismatch\n";
    ok = false;
  }

  r3_media_decoded_frame_release(frame);
  if (frame->rgba != nullptr || frame->byte_length != 0) {
    std::cerr << "frame release did not clear ownership\n";
    ok = false;
  }
  return ok;
}

bool CheckFrame(void* decoder, int64_t source_frame) {
  R3MediaDecodedFrame frame = {};
  const int result = r3_media_decoder_render(
      decoder,
      source_frame,
      320,
      180,
      &frame);
  if (result != 0) {
    std::cerr << "decode failed at frame " << source_frame << ": "
              << DecoderError(decoder) << "\n";
    return false;
  }
  return ValidateFrame(&frame, source_frame);
}

bool CheckAsyncFrame(void* decoder, int64_t source_frame) {
  if (r3_media_decoder_request(decoder, source_frame, 320, 180) != 0) {
    std::cerr << "async request failed at frame " << source_frame << ": "
              << DecoderError(decoder) << "\n";
    return false;
  }

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < deadline) {
    R3MediaDecodedFrame frame = {};
    const int status = r3_media_decoder_poll(
        decoder,
        source_frame,
        320,
        180,
        &frame);
    if (status < 0) {
      std::cerr << "async poll failed at frame " << source_frame << ": "
                << DecoderError(decoder) << "\n";
      return false;
    }
    if (status == 1) {
      return ValidateFrame(&frame, source_frame);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }

  std::cerr << "async decode timed out at frame " << source_frame << "\n";
  return false;
}

bool CheckFrameSink(void* decoder, int64_t source_frame) {
  // Establish the desired target before attaching the sink. set_frame_sink()
  // intentionally publishes an already-cached current target immediately, so
  // binding first would allow the previous test target to satisfy the probe and
  // make this regression measure the wrong frame.
  if (r3_media_decoder_request(decoder, source_frame, 320, 180) != 0) {
    std::cerr << "sink request failed at frame " << source_frame << ": "
              << DecoderError(decoder) << "\n";
    return false;
  }

  SinkProbe probe;
  if (r3_media_decoder_set_frame_sink(decoder, ProbeSink, &probe) != 0) {
    std::cerr << "frame sink bind failed: " << DecoderError(decoder) << "\n";
    return false;
  }

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < deadline &&
         probe.calls.load(std::memory_order_acquire) == 0) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }

  const bool detached =
      r3_media_decoder_set_frame_sink(decoder, nullptr, nullptr) == 0;
  if (!detached) {
    std::cerr << "frame sink detach failed: " << DecoderError(decoder) << "\n";
    return false;
  }

  if (probe.calls.load(std::memory_order_acquire) <= 0) {
    std::cerr << "frame sink timed out at frame " << source_frame << "\n";
    return false;
  }
  if (probe.requested_frame.load(std::memory_order_relaxed) != source_frame ||
      probe.actual_frame.load(std::memory_order_relaxed) != source_frame) {
    std::cerr << "frame sink position mismatch\n";
    return false;
  }
  if (probe.width.load(std::memory_order_relaxed) != 320 ||
      probe.height.load(std::memory_order_relaxed) != 180 ||
      probe.stride.load(std::memory_order_relaxed) != 320 * 4) {
    std::cerr << "frame sink geometry mismatch\n";
    return false;
  }
  const int64_t expected_bytes = static_cast<int64_t>(320) * 180 * 4;
  if (probe.byte_length.load(std::memory_order_relaxed) != expected_bytes ||
      probe.has_pixels.load(std::memory_order_relaxed) == 0) {
    std::cerr << "frame sink RGBA mismatch\n";
    return false;
  }

  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: media_decoder_test <clip>\n";
    return 2;
  }

  void* decoder = r3_media_decoder_create(argv[1]);
  if (decoder == nullptr) {
    std::cerr << "create failed: " << CreateError() << "\n";
    return 1;
  }

  bool ok = true;
  const int64_t length = r3_media_decoder_length(decoder);
  if (length != 60) {
    std::cerr << "source length mismatch: expected 60, got " << length << "\n";
    ok = false;
  }

  const int64_t fps_num = r3_media_decoder_fps_num(decoder);
  const int64_t fps_den = r3_media_decoder_fps_den(decoder);
  if (fps_num != 30 || fps_den != 1) {
    std::cerr << "source fps mismatch: expected 30/1, got "
              << fps_num << "/" << fps_den << "\n";
    ok = false;
  }

  // Preserve the original exact synchronous regression. The implementation is
  // now backed by the worker, but callers still receive the requested frame.
  const std::vector<int64_t> exact_requests = {0, 40, 10, 35, 1, 50};
  for (const int64_t frame : exact_requests) {
    if (!CheckFrame(decoder, frame)) {
      ok = false;
      break;
    }
  }

  // Prove the live request/poll path independently. It must return pending
  // rather than block while the worker catches up, then produce the exact frame.
  if (ok) {
    const std::vector<int64_t> async_requests = {12, 13, 4};
    for (const int64_t frame : async_requests) {
      if (!CheckAsyncFrame(decoder, frame)) {
        ok = false;
        break;
      }
    }
  }

  // Native presentation is a subscriber to the same worker, not a second
  // decoder or MLT consumer. Verify that the sink sees exactly the requested
  // target with valid borrowed RGBA bytes.
  if (ok && !CheckFrameSink(decoder, 22)) {
    ok = false;
  }

  r3_media_decoder_destroy(decoder);

  if (!ok) return 1;

  std::cout << "media_decoder_test: PASS\n";
  return 0;
}
