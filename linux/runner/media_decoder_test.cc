// ./linux/runner/media_decoder_test.cc

#include "media_decoder.h"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

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

  bool ok = true;
  if (frame.requested_frame != source_frame) {
    std::cerr << "requested frame mismatch\n";
    ok = false;
  }
  if (frame.actual_frame != source_frame) {
    std::cerr << "actual frame mismatch: requested " << source_frame
              << ", actual " << frame.actual_frame << "\n";
    ok = false;
  }
  if (frame.width != 320 || frame.height != 180) {
    std::cerr << "decoded size mismatch: " << frame.width << "x"
              << frame.height << "\n";
    ok = false;
  }
  if (frame.stride != frame.width * 4) {
    std::cerr << "RGBA stride mismatch\n";
    ok = false;
  }
  const int64_t expected_bytes =
      static_cast<int64_t>(frame.width) * frame.height * 4;
  if (frame.byte_length != expected_bytes || frame.rgba == nullptr) {
    std::cerr << "RGBA buffer mismatch\n";
    ok = false;
  }

  r3_media_decoded_frame_release(&frame);
  if (frame.rgba != nullptr || frame.byte_length != 0) {
    std::cerr << "frame release did not clear ownership\n";
    ok = false;
  }
  return ok;
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

  const std::vector<int64_t> requests = {0, 40, 10, 35, 1, 50};
  for (const int64_t frame : requests) {
    if (!CheckFrame(decoder, frame)) {
      ok = false;
      break;
    }
  }

  r3_media_decoder_destroy(decoder);

  if (!ok) {
    return 1;
  }

  std::cout << "media_decoder_test: PASS\n";
  return 0;
}
