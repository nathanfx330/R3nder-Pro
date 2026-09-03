// ./linux/runner/edit_preview_texture.h
//
// Native MLT preview texture for the source-backed EDIT monitor.
//
// R3nder owns project time and edit geometry. This bridge is only a display
// follower: Dart tells it which source frame should be visible or where
// continuous source playback should begin. MLT renders on its own consumer
// threads and hands completed RGBA frames to Flutter through an external GL
// texture, matching the proven MLT Player preview architecture.

#ifndef R3NDER_EDIT_PREVIEW_TEXTURE_H_
#define R3NDER_EDIT_PREVIEW_TEXTURE_H_

#include <flutter_linux/flutter_linux.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int64_t r3_edit_preview_register_flutter_texture(
    FlTextureRegistrar* registrar);
void r3_edit_preview_unregister_flutter_texture(void);
int64_t r3_edit_preview_texture_id(void);

int r3_edit_preview_open(const char* path, int width, int height);
void r3_edit_preview_close(void);

int r3_edit_preview_seek_frame(int64_t source_frame);
int r3_edit_preview_play_from(
    int64_t source_frame,
    int64_t project_fps_num,
    int64_t project_fps_den,
    int64_t speed_num,
    int64_t speed_den);
int r3_edit_preview_pause_at(int64_t source_frame);

int64_t r3_edit_preview_position_frame(void);
double r3_edit_preview_source_fps(void);
int r3_edit_preview_is_playing(void);

int r3_edit_preview_set_output_size(int width, int height);
int r3_edit_preview_copy_last_error(char* buffer, int capacity);

#ifdef __cplusplus
}
#endif

#endif  // R3NDER_EDIT_PREVIEW_TEXTURE_H_
