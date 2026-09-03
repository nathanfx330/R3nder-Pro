// ./linux/runner/media_decoder.h
//
// Persistent MLT-backed media decoder ABI for Dart FFI.
//
// R3nder owns project time and clip geometry. MLT owns only source decoding.
// The synchronous render entry point remains for exact parked-frame work. Live
// preview uses request/poll so decode can run ahead on a native worker without
// ever blocking the Dart isolate that feeds audio and paints the editor.
// Native presentation may subscribe to exact target frames through a sink
// callback without making the decoder depend on Flutter.

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

// Called on the decoder worker thread only for the exact current target frame.
// The pixel pointer is borrowed and valid only for the duration of the call.
// A sink must copy or consume the bytes before returning and must not call back
// into the same decoder while the callback is running.
typedef void (*R3MediaDecodedFrameSink)(
    void* decoder_handle,
    int64_t requested_frame,
    int64_t actual_frame,
    int32_t width,
    int32_t height,
    int32_t stride,
    const uint8_t* rgba,
    int64_t byte_length,
    void* user_data);

void* r3_media_decoder_create(const char* path);
void r3_media_decoder_destroy(void* handle);

// Descriptive source metadata only. None of these calls changes project time.
int64_t r3_media_decoder_length(void* handle);
int64_t r3_media_decoder_fps_num(void* handle);
int64_t r3_media_decoder_fps_den(void* handle);

// Exact parked-frame path. Returns 0 on success and -1 on failure. The native
// worker is still the sole owner of the MLT producer; this call publishes the
// request and waits for that worker to make the exact frame available.
int r3_media_decoder_render(
    void* handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height,
    R3MediaDecodedFrame* out_frame);

// Nonblocking live-preview path. request() only publishes the newest desired
// source frame and output size. poll() returns 1 when that exact frame is ready,
// 0 while it is still pending, and -1 on decoder failure. Neither call waits on
// MLT decode. Repeated requests allow the worker to decode ahead; large jumps
// invalidate stale read-ahead and cause one new seek on the worker.
int r3_media_decoder_request(
    void* handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height);

int r3_media_decoder_poll(
    void* handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height,
    R3MediaDecodedFrame* out_frame);

// Optional native presentation hook. The decoder remains Flutter-agnostic: it
// simply calls the supplied sink when the exact current target is decoded or
// is already present in its cache. Passing a null sink detaches presentation.
int r3_media_decoder_set_frame_sink(
    void* handle,
    R3MediaDecodedFrameSink sink,
    void* user_data);

void r3_media_decoded_frame_release(R3MediaDecodedFrame* frame);

int r3_media_decoder_copy_last_error(
    void* handle,
    char* buffer,
    int32_t capacity);

int r3_media_decoder_copy_create_error(char* buffer, int32_t capacity);

#ifdef __cplusplus
}
#endif
