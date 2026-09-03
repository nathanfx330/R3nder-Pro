// ./linux/runner/media_decoder.cc

#include "media_decoder.h"

#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>

extern "C" {
#include <framework/mlt.h>
}

namespace {

struct MediaDecoderState {
  mlt_profile profile = nullptr;
  mlt_producer producer = nullptr;
  std::mutex mutex;
  std::string last_error;
};

std::once_flag g_factory_once;
bool g_factory_ready = false;
std::mutex g_create_error_mutex;
std::string g_create_error;

void SetCreateError(const std::string& message) {
  std::lock_guard<std::mutex> lock(g_create_error_mutex);
  g_create_error = message;
}

void EnsureFactory() {
  std::call_once(g_factory_once, []() {
    g_factory_ready = mlt_factory_init(nullptr) != nullptr;
    if (!g_factory_ready) {
      SetCreateError("MLT factory initialization failed.");
    }
  });
}

int CopyString(const std::string& value, char* buffer, int32_t capacity) {
  const int full_length = static_cast<int>(value.size());
  if (buffer == nullptr || capacity <= 0) {
    return full_length;
  }

  const int writable = capacity - 1;
  const int count = full_length < writable ? full_length : writable;
  if (count > 0) {
    std::memcpy(buffer, value.data(), static_cast<size_t>(count));
  }
  buffer[count] = '\0';
  return full_length;
}

void ResetFrame(R3MediaDecodedFrame* frame) {
  if (frame == nullptr) return;
  frame->requested_frame = 0;
  frame->actual_frame = 0;
  frame->width = 0;
  frame->height = 0;
  frame->stride = 0;
  frame->reserved = 0;
  frame->byte_length = 0;
  frame->rgba = nullptr;
}

int Fail(MediaDecoderState* state, const std::string& message) {
  if (state != nullptr) {
    state->last_error = message;
  }
  return -1;
}

}  // namespace

extern "C" void* r3_media_decoder_create(const char* path) {
  EnsureFactory();
  if (!g_factory_ready) {
    return nullptr;
  }
  if (path == nullptr || path[0] == '\0') {
    SetCreateError("Media decoder path is empty.");
    return nullptr;
  }

  MediaDecoderState* state = new MediaDecoderState();
  state->profile = mlt_profile_init(nullptr);
  if (state->profile == nullptr) {
    SetCreateError("MLT profile allocation failed.");
    delete state;
    return nullptr;
  }

  // MLT constructs a producer against the profile that exists at creation
  // time. Calling mlt_profile_from_producer() only after keeping that producer
  // alive leaves the producer and profile in different frame-rate domains. In
  // practice that can turn an exact source-frame seek into the adjacent frame.
  //
  // Open once only to discover the source-native profile, close that temporary
  // producer, then create the persistent decoder against the matched profile.
  // The M8 backend bakeoff used an already-correct profile before producer
  // creation and returned every requested frame exactly; this two-stage open
  // gives arbitrary source media the same invariant.
  mlt_producer probe = mlt_factory_producer(state->profile, nullptr, path);
  if (probe == nullptr) {
    SetCreateError(std::string("MLT could not probe media: ") + path);
    mlt_profile_close(state->profile);
    delete state;
    return nullptr;
  }

  mlt_profile_from_producer(state->profile, probe);
  mlt_producer_close(probe);

  state->producer = mlt_factory_producer(state->profile, nullptr, path);
  if (state->producer == nullptr) {
    SetCreateError(std::string("MLT could not open media: ") + path);
    mlt_profile_close(state->profile);
    delete state;
    return nullptr;
  }

  mlt_producer_set_speed(state->producer, 0.0);
  state->last_error.clear();
  SetCreateError("");
  return state;
}

extern "C" void r3_media_decoder_destroy(void* handle) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr) return;

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->producer != nullptr) {
      mlt_producer_close(state->producer);
      state->producer = nullptr;
    }
    if (state->profile != nullptr) {
      mlt_profile_close(state->profile);
      state->profile = nullptr;
    }
  }

  delete state;
}

extern "C" int64_t r3_media_decoder_length(void* handle) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr) return -1;

  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->producer == nullptr) {
    state->last_error = "Media decoder is closed.";
    return -1;
  }

  const mlt_position length = mlt_producer_get_length(state->producer);
  if (length <= 0) {
    state->last_error = "MLT reported an invalid media length.";
    return -1;
  }

  state->last_error.clear();
  return static_cast<int64_t>(length);
}

extern "C" int r3_media_decoder_render(
    void* handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height,
    R3MediaDecodedFrame* out_frame) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr || out_frame == nullptr) {
    return -1;
  }

  ResetFrame(out_frame);
  std::lock_guard<std::mutex> lock(state->mutex);

  if (state->producer == nullptr) {
    return Fail(state, "Media decoder is closed.");
  }
  if (requested_frame < 0) {
    return Fail(state, "Requested source frame must be non-negative.");
  }
  if (width <= 0 || height <= 0) {
    return Fail(state, "Requested output size must be positive.");
  }

  if (mlt_producer_seek(
          state->producer,
          static_cast<mlt_position>(requested_frame)) != 0) {
    return Fail(state, "MLT seek failed.");
  }

  mlt_frame frame = nullptr;
  if (mlt_service_get_frame(
          MLT_PRODUCER_SERVICE(state->producer),
          &frame,
          0) != 0 ||
      frame == nullptr) {
    return Fail(state, "MLT could not produce the requested frame.");
  }

  const mlt_position actual_position = mlt_frame_get_position(frame);
  mlt_image_format format = mlt_image_rgba;
  int decoded_width = width;
  int decoded_height = height;
  uint8_t* image = nullptr;

  const int image_error = mlt_frame_get_image(
      frame,
      &image,
      &format,
      &decoded_width,
      &decoded_height,
      0);

  if (image_error != 0 || image == nullptr) {
    mlt_frame_close(frame);
    return Fail(state, "MLT image decode failed.");
  }
  if (format != mlt_image_rgba) {
    mlt_frame_close(frame);
    return Fail(state, "MLT did not return requested RGBA image data.");
  }
  if (decoded_width <= 0 || decoded_height <= 0) {
    mlt_frame_close(frame);
    return Fail(state, "MLT returned an invalid frame size.");
  }

  const int64_t pixel_count =
      static_cast<int64_t>(decoded_width) * static_cast<int64_t>(decoded_height);
  if (pixel_count > std::numeric_limits<int64_t>::max() / 4) {
    mlt_frame_close(frame);
    return Fail(state, "Decoded frame byte count overflowed.");
  }
  const int64_t byte_length = pixel_count * 4;
  uint8_t* copy = static_cast<uint8_t*>(
      std::malloc(static_cast<size_t>(byte_length)));
  if (copy == nullptr) {
    mlt_frame_close(frame);
    return Fail(state, "Could not allocate decoded RGBA frame buffer.");
  }

  std::memcpy(copy, image, static_cast<size_t>(byte_length));
  mlt_frame_close(frame);

  out_frame->requested_frame = requested_frame;
  out_frame->actual_frame = static_cast<int64_t>(actual_position);
  out_frame->width = decoded_width;
  out_frame->height = decoded_height;
  out_frame->stride = decoded_width * 4;
  out_frame->reserved = 0;
  out_frame->byte_length = byte_length;
  out_frame->rgba = copy;
  state->last_error.clear();
  return 0;
}

extern "C" void r3_media_decoded_frame_release(R3MediaDecodedFrame* frame) {
  if (frame == nullptr) return;
  std::free(frame->rgba);
  ResetFrame(frame);
}

extern "C" int r3_media_decoder_copy_last_error(
    void* handle,
    char* buffer,
    int32_t capacity) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr) {
    return CopyString("Media decoder handle is null.", buffer, capacity);
  }

  std::lock_guard<std::mutex> lock(state->mutex);
  return CopyString(state->last_error, buffer, capacity);
}

extern "C" int r3_media_decoder_copy_create_error(
    char* buffer,
    int32_t capacity) {
  std::lock_guard<std::mutex> lock(g_create_error_mutex);
  return CopyString(g_create_error, buffer, capacity);
}
