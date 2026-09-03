// ./linux/runner/media_decoder.h
//
// Persistent MLT-backed media decoder ABI for Dart FFI.
//
// R3nder owns project time and clip geometry. This bridge accepts only a
// concrete source-frame request plus an output size. MLT never owns the
// project playhead, edit duration, or seek epoch.

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct R3MediaDecodedFrame {
  int64_t requested_frame;
  int64_t actual_frame;
  int32_t width;
  int32_t height;
  int32_t stride;
  int32_t reserved;
  int64_t byte_length;
  uint8_t* rgba;
} R3MediaDecodedFrame;

void* r3_media_decoder_create(const char* path);
void r3_media_decoder_destroy(void* handle);

// Returns the producer length in source-native frames, or -1 if the decoder
// is invalid or closed. This is descriptive source metadata only. It never
// changes project duration or advances the producer.
int64_t r3_media_decoder_length(void* handle);

// Returns the exact source-profile frame-rate rational, or -1 when unavailable.
// Import uses this only once to conform source time to R3nder project time.
int64_t r3_media_decoder_fps_num(void* handle);
int64_t r3_media_decoder_fps_den(void* handle);

// Returns 0 on success and -1 on failure. The caller owns out_frame->rgba on
// success and must release it through r3_media_decoded_frame_release().
int r3_media_decoder_render(
    void* handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height,
    R3MediaDecodedFrame* out_frame);

void r3_media_decoded_frame_release(R3MediaDecodedFrame* frame);

int r3_media_decoder_copy_last_error(
    void* handle,
    char* buffer,
    int32_t capacity);

int r3_media_decoder_copy_create_error(char* buffer, int32_t capacity);

#ifdef __cplusplus
}
#endif
