// ./linux/runner/media_decoder.cc
//
// Persistent MLT source decoder with native decode-ahead.
//
// The MLT producer is owned by one native worker thread for its entire useful
// lifetime. Dart may publish target frames and poll completed RGBA frames, but
// it never performs seek/decode work on the UI isolate. Exact parked-frame
// render remains available and waits on the same worker instead of touching the
// producer from a second thread.

#include "media_decoder.h"

#include <algorithm>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

extern "C" {
#include <framework/mlt.h>
}

namespace {

constexpr std::size_t kFrameCacheLimit = 16;
constexpr int64_t kReadAheadFrames = 8;
constexpr int64_t kJumpThresholdFrames = 6;

struct CachedFrame {
  int64_t requested_frame = -1;
  int64_t actual_frame = -1;
  int32_t width = 0;
  int32_t height = 0;
  int32_t stride = 0;
  std::vector<uint8_t> rgba;
};

struct MediaDecoderState {
  mlt_profile profile = nullptr;
  mlt_producer producer = nullptr;

  int64_t length = 0;
  int64_t fps_num = 0;
  int64_t fps_den = 0;

  std::mutex mutex;
  std::condition_variable cv;
  std::deque<CachedFrame> cache;

  bool closing = false;
  bool failed = false;
  bool target_valid = false;
  bool worker_exited = false;

  int64_t target_frame = -1;
  int32_t target_width = 0;
  int32_t target_height = 0;

  // The next source frame the worker expects to decode sequentially. A real
  // backward/far-forward jump resets this to target_frame and performs one
  // producer seek. Otherwise the worker keeps asking MLT for the next frame.
  int64_t next_decode_frame = -1;
  int32_t decode_width = 0;
  int32_t decode_height = 0;

  std::string last_error;
  std::thread worker;
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
    std::memcpy(buffer, value.data(), static_cast<std::size_t>(count));
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

void SetFailureLocked(MediaDecoderState* state, const std::string& message) {
  state->failed = true;
  state->last_error = message;
}

bool FrameMatches(
    const CachedFrame& frame,
    int64_t requested_frame,
    int32_t width,
    int32_t height) {
  return frame.requested_frame == requested_frame &&
         frame.width == width &&
         frame.height == height;
}

const CachedFrame* FindFrameLocked(
    const MediaDecoderState* state,
    int64_t requested_frame,
    int32_t width,
    int32_t height) {
  for (auto it = state->cache.rbegin(); it != state->cache.rend(); ++it) {
    if (FrameMatches(*it, requested_frame, width, height)) {
      return &*it;
    }
  }
  return nullptr;
}

bool CopyCachedFrame(
    const CachedFrame& source,
    R3MediaDecodedFrame* out_frame) {
  if (out_frame == nullptr || source.rgba.empty()) return false;

  const int64_t byte_length = static_cast<int64_t>(source.rgba.size());
  uint8_t* copy = static_cast<uint8_t*>(
      std::malloc(static_cast<std::size_t>(byte_length)));
  if (copy == nullptr) return false;

  std::memcpy(copy, source.rgba.data(), static_cast<std::size_t>(byte_length));
  out_frame->requested_frame = source.requested_frame;
  out_frame->actual_frame = source.actual_frame;
  out_frame->width = source.width;
  out_frame->height = source.height;
  out_frame->stride = source.stride;
  out_frame->reserved = 0;
  out_frame->byte_length = byte_length;
  out_frame->rgba = copy;
  return true;
}

bool ValidRequestLocked(
    MediaDecoderState* state,
    int64_t requested_frame,
    int32_t width,
    int32_t height) {
  if (state->closing) {
    state->last_error = "Media decoder is closing.";
    return false;
  }
  if (state->failed) return false;
  if (requested_frame < 0) {
    state->last_error = "Requested source frame must be non-negative.";
    return false;
  }
  if (state->length <= 0 || requested_frame >= state->length) {
    state->last_error = "Requested source frame is outside the media length.";
    return false;
  }
  if (width <= 0 || height <= 0) {
    state->last_error = "Requested output size must be positive.";
    return false;
  }
  return true;
}

bool PublishRequestLocked(
    MediaDecoderState* state,
    int64_t requested_frame,
    int32_t width,
    int32_t height) {
  if (!ValidRequestLocked(state, requested_frame, width, height)) {
    return false;
  }

  const bool size_changed =
      state->target_valid &&
      (state->target_width != width || state->target_height != height);

  state->target_valid = true;
  state->target_frame = requested_frame;
  state->target_width = width;
  state->target_height = height;
  state->last_error.clear();

  if (size_changed) {
    state->cache.clear();
    state->next_decode_frame = requested_frame;
    state->decode_width = width;
    state->decode_height = height;
  }
  return true;
}

bool WorkerHasWorkLocked(const MediaDecoderState* state) {
  if (!state->target_valid || state->closing || state->failed) return false;

  const bool size_changed =
      state->decode_width != state->target_width ||
      state->decode_height != state->target_height;
  if (size_changed || state->next_decode_frame < 0) return true;

  const CachedFrame* exact = FindFrameLocked(
      state,
      state->target_frame,
      state->target_width,
      state->target_height);

  if (exact == nullptr) {
    if (state->target_frame < state->next_decode_frame) return true;
    if (state->target_frame >
        state->next_decode_frame + kJumpThresholdFrames) {
      return true;
    }
    return state->next_decode_frame <= state->target_frame;
  }

  const int64_t goal = std::min(
      state->length - 1,
      state->target_frame + kReadAheadFrames);
  return state->next_decode_frame <= goal;
}

int64_t SelectDecodeFrameLocked(MediaDecoderState* state) {
  const bool size_changed =
      state->decode_width != state->target_width ||
      state->decode_height != state->target_height;
  const CachedFrame* exact = FindFrameLocked(
      state,
      state->target_frame,
      state->target_width,
      state->target_height);

  if (size_changed || state->next_decode_frame < 0) {
    state->cache.clear();
    state->next_decode_frame = state->target_frame;
    state->decode_width = state->target_width;
    state->decode_height = state->target_height;
  } else if (exact == nullptr &&
             (state->target_frame < state->next_decode_frame ||
              state->target_frame >
                  state->next_decode_frame + kJumpThresholdFrames)) {
    // This is a real seek, not ordinary linear playback. Discard read-ahead
    // from the old neighborhood so the worker cannot present it later.
    state->cache.clear();
    state->next_decode_frame = state->target_frame;
  }

  return state->next_decode_frame;
}

bool DecodeExactFrame(
    MediaDecoderState* state,
    int64_t requested_frame,
    int32_t width,
    int32_t height,
    CachedFrame* out,
    std::string* error) {
  if (state->producer == nullptr || out == nullptr || error == nullptr) {
    if (error != nullptr) *error = "Media decoder producer is closed.";
    return false;
  }

  // During linear decode the producer should already be positioned at the next
  // frame. Only seek when it is not. This preserves MLT's sequential decoder
  // state and allows the native worker to build read-ahead instead of forcing a
  // random-access operation for every project frame.
  if (static_cast<int64_t>(mlt_producer_position(state->producer)) !=
      requested_frame) {
    if (mlt_producer_seek(
            state->producer,
            static_cast<mlt_position>(requested_frame)) != 0) {
      *error = "MLT seek failed.";
      return false;
    }
  }

  mlt_frame frame = nullptr;
  if (mlt_service_get_frame(
          MLT_PRODUCER_SERVICE(state->producer),
          &frame,
          0) != 0 ||
      frame == nullptr) {
    *error = "MLT could not produce the requested frame.";
    return false;
  }

  const int64_t actual_position =
      static_cast<int64_t>(mlt_frame_get_position(frame));
  if (actual_position != requested_frame) {
    mlt_frame_close(frame);

    // Correctness wins over read-ahead. If a producer service did not advance
    // the way its position predicted, perform one exact seek and retry rather
    // than allowing an adjacent frame into the cache.
    if (mlt_producer_seek(
            state->producer,
            static_cast<mlt_position>(requested_frame)) != 0) {
      *error = "MLT exact-frame recovery seek failed.";
      return false;
    }
    frame = nullptr;
    if (mlt_service_get_frame(
            MLT_PRODUCER_SERVICE(state->producer),
            &frame,
            0) != 0 ||
        frame == nullptr) {
      *error = "MLT exact-frame recovery decode failed.";
      return false;
    }
    if (static_cast<int64_t>(mlt_frame_get_position(frame)) !=
        requested_frame) {
      mlt_frame_close(frame);
      *error = "MLT returned a different source frame than requested.";
      return false;
    }
  }

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
    *error = "MLT image decode failed.";
    return false;
  }
  if (format != mlt_image_rgba) {
    mlt_frame_close(frame);
    *error = "MLT did not return requested RGBA image data.";
    return false;
  }
  if (decoded_width <= 0 || decoded_height <= 0) {
    mlt_frame_close(frame);
    *error = "MLT returned an invalid frame size.";
    return false;
  }

  const int64_t pixel_count =
      static_cast<int64_t>(decoded_width) *
      static_cast<int64_t>(decoded_height);
  if (pixel_count <= 0 ||
      pixel_count > std::numeric_limits<int64_t>::max() / 4) {
    mlt_frame_close(frame);
    *error = "Decoded frame byte count overflowed.";
    return false;
  }
  const int64_t byte_length = pixel_count * 4;
  if (static_cast<uint64_t>(byte_length) >
      static_cast<uint64_t>(std::numeric_limits<std::size_t>::max())) {
    mlt_frame_close(frame);
    *error = "Decoded frame is too large for this process.";
    return false;
  }

  CachedFrame decoded;
  decoded.requested_frame = requested_frame;
  decoded.actual_frame = requested_frame;
  decoded.width = decoded_width;
  decoded.height = decoded_height;
  decoded.stride = decoded_width * 4;
  decoded.rgba.resize(static_cast<std::size_t>(byte_length));
  std::memcpy(
      decoded.rgba.data(),
      image,
      static_cast<std::size_t>(byte_length));
  mlt_frame_close(frame);

  *out = std::move(decoded);
  return true;
}

void StoreFrameLocked(MediaDecoderState* state, CachedFrame frame) {
  for (auto it = state->cache.begin(); it != state->cache.end(); ++it) {
    if (FrameMatches(
            *it,
            frame.requested_frame,
            frame.width,
            frame.height)) {
      *it = std::move(frame);
      return;
    }
  }

  state->cache.push_back(std::move(frame));
  while (state->cache.size() > kFrameCacheLimit) {
    state->cache.pop_front();
  }
}

void WorkerMain(MediaDecoderState* state) {
  for (;;) {
    int64_t requested_frame = -1;
    int32_t width = 0;
    int32_t height = 0;

    {
      std::unique_lock<std::mutex> lock(state->mutex);
      state->cv.wait(lock, [&]() {
        return state->closing || state->failed || WorkerHasWorkLocked(state);
      });

      if (state->closing || state->failed) break;
      requested_frame = SelectDecodeFrameLocked(state);
      width = state->target_width;
      height = state->target_height;
    }

    CachedFrame decoded;
    std::string error;
    if (!DecodeExactFrame(
            state,
            requested_frame,
            width,
            height,
            &decoded,
            &error)) {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->closing) SetFailureLocked(state, error);
      state->cv.notify_all();
      break;
    }

    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->closing) break;

      // A size change that arrived while this frame decoded invalidates the
      // pixels, but not the decoder. Drop them and let the next loop honor the
      // new target dimensions.
      if (width == state->target_width && height == state->target_height) {
        StoreFrameLocked(state, std::move(decoded));
        state->next_decode_frame = requested_frame + 1;
        state->decode_width = width;
        state->decode_height = height;
      }
      state->cv.notify_all();
    }
  }

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->worker_exited = true;
  }
  state->cv.notify_all();
}

void CloseNativeObjects(MediaDecoderState* state) {
  if (state->producer != nullptr) {
    mlt_producer_close(state->producer);
    state->producer = nullptr;
  }
  if (state->profile != nullptr) {
    mlt_profile_close(state->profile);
    state->profile = nullptr;
  }
}

}  // namespace

extern "C" void* r3_media_decoder_create(const char* path) {
  EnsureFactory();
  if (!g_factory_ready) return nullptr;
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

  // Match the profile before constructing the persistent producer. This is the
  // exact-frame invariant established by M8 and retained by M9.
  mlt_producer probe = mlt_factory_producer(state->profile, nullptr, path);
  if (probe == nullptr) {
    SetCreateError(std::string("MLT could not probe media: ") + path);
    CloseNativeObjects(state);
    delete state;
    return nullptr;
  }

  mlt_profile_from_producer(state->profile, probe);
  mlt_producer_close(probe);

  state->producer = mlt_factory_producer(state->profile, nullptr, path);
  if (state->producer == nullptr) {
    SetCreateError(std::string("MLT could not open media: ") + path);
    CloseNativeObjects(state);
    delete state;
    return nullptr;
  }

  state->length = static_cast<int64_t>(mlt_producer_get_length(state->producer));
  state->fps_num = static_cast<int64_t>(state->profile->frame_rate_num);
  state->fps_den = static_cast<int64_t>(state->profile->frame_rate_den);
  if (state->length <= 0 || state->fps_num <= 0 || state->fps_den <= 0) {
    SetCreateError("MLT reported invalid media timing metadata.");
    CloseNativeObjects(state);
    delete state;
    return nullptr;
  }

  // Speed is decoder-cursor state only. It does not pace presentation. With a
  // producer-only worker, speed 1 lets sequential get_frame calls preserve
  // codec state and advance naturally while ProjectClock remains the sole
  // authority deciding which source frame the UI asks to present.
  mlt_producer_set_speed(state->producer, 1.0);
  mlt_producer_seek(state->producer, 0);

  try {
    state->worker = std::thread(WorkerMain, state);
  } catch (...) {
    SetCreateError("Could not start native media decode worker.");
    CloseNativeObjects(state);
    delete state;
    return nullptr;
  }

  state->last_error.clear();
  SetCreateError("");
  return state;
}

extern "C" void r3_media_decoder_destroy(void* handle) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr) return;

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->closing = true;
  }
  state->cv.notify_all();

  if (state->worker.joinable()) {
    state->worker.join();
  }

  CloseNativeObjects(state);
  delete state;
}

extern "C" int64_t r3_media_decoder_length(void* handle) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr) return -1;
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->closing || state->length <= 0) return -1;
  state->last_error.clear();
  return state->length;
}

extern "C" int64_t r3_media_decoder_fps_num(void* handle) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr) return -1;
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->closing || state->fps_num <= 0) return -1;
  state->last_error.clear();
  return state->fps_num;
}

extern "C" int64_t r3_media_decoder_fps_den(void* handle) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr) return -1;
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->closing || state->fps_den <= 0) return -1;
  state->last_error.clear();
  return state->fps_den;
}

extern "C" int r3_media_decoder_request(
    void* handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr) return -1;

  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!PublishRequestLocked(state, requested_frame, width, height)) {
      return -1;
    }
  }
  state->cv.notify_all();
  return 0;
}

extern "C" int r3_media_decoder_poll(
    void* handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height,
    R3MediaDecodedFrame* out_frame) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr || out_frame == nullptr) return -1;
  ResetFrame(out_frame);

  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->failed) return -1;
  if (state->closing) {
    state->last_error = "Media decoder is closing.";
    return -1;
  }

  const CachedFrame* frame =
      FindFrameLocked(state, requested_frame, width, height);
  if (frame == nullptr) return 0;
  if (!CopyCachedFrame(*frame, out_frame)) {
    state->last_error = "Could not allocate decoded RGBA frame copy.";
    return -1;
  }
  state->last_error.clear();
  return 1;
}

extern "C" int r3_media_decoder_render(
    void* handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height,
    R3MediaDecodedFrame* out_frame) {
  MediaDecoderState* state = static_cast<MediaDecoderState*>(handle);
  if (state == nullptr || out_frame == nullptr) return -1;
  ResetFrame(out_frame);

  std::unique_lock<std::mutex> lock(state->mutex);
  if (!PublishRequestLocked(state, requested_frame, width, height)) {
    return -1;
  }
  state->cv.notify_all();

  state->cv.wait(lock, [&]() {
    return state->closing || state->failed ||
           FindFrameLocked(state, requested_frame, width, height) != nullptr;
  });

  if (state->failed || state->closing) return -1;
  const CachedFrame* frame =
      FindFrameLocked(state, requested_frame, width, height);
  if (frame == nullptr) {
    state->last_error = "Native media worker did not produce the requested frame.";
    return -1;
  }
  if (!CopyCachedFrame(*frame, out_frame)) {
    state->last_error = "Could not allocate decoded RGBA frame copy.";
    return -1;
  }
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
