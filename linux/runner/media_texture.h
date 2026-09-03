// ./linux/runner/media_texture.h
//
// Flutter external texture bridge for frames produced by media_decoder.cc.
//
// ProjectClock still chooses every requested source frame in Dart. This bridge
// only receives the decoder's exact current target and exposes those pixels to
// Flutter without copying RGBA through Dart or rebuilding the widget tree.

#pragma once

#include <flutter_linux/flutter_linux.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int64_t r3_media_texture_register_flutter_texture(
    FlTextureRegistrar* registrar);

void r3_media_texture_unregister_flutter_texture(void);

int64_t r3_media_texture_id(void);

// Bind the texture to one persistent decoder and publish a new exact target.
// Returns 0 when the request was accepted and -1 on failure. Decode remains
// asynchronous and is performed by the decoder's existing native worker.
int r3_media_texture_request(
    void* decoder_handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height);

// Called before a decoder is destroyed. Safe to call for a decoder that is not
// currently feeding the external texture.
void r3_media_texture_detach_decoder(void* decoder_handle);

#ifdef __cplusplus
}
#endif
