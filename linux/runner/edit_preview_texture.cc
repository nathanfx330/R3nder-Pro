// ./linux/runner/edit_preview_texture.cc
//
// MLT-backed external Flutter texture for EDIT preview.
//
// This is deliberately shaped after the proven MLT Player preview path:
// MLT's consumer renders frames on its own threads, the frame-show callback
// only copies already-rendered RGBA into a three-slot rotation, and Flutter's
// raster thread uploads the newest completed slot into an external GL texture.
//
// R3nder still owns the project playhead. This bridge never decides edit
// geometry or project duration. It follows explicit source-frame seeks and a
// source playback speed derived from R3nder's ProjectClock rate.

#include "edit_preview_texture.h"

#include <epoxy/gl.h>

#include <framework/mlt.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>

namespace {

constexpr int kSlotCount = 3;
constexpr char kDeinterlacer[] = "onefield";

struct FrameSlot {
  uint8_t* data = nullptr;
  size_t capacity = 0;
  int width = 0;
  int height = 0;
};

std::once_flag g_init_once;
std::once_flag g_factory_once;
bool g_factory_ready = false;

GMutex g_engine_mutex;
GMutex g_frame_mutex;
GMutex g_texture_mutex;

mlt_profile g_profile = nullptr;
mlt_producer g_producer = nullptr;
mlt_consumer g_consumer = nullptr;

double g_source_fps = 0.0;
std::string g_last_error;

gint g_target_width = 0;
gint g_target_height = 0;

FrameSlot g_slots[kSlotCount];
int g_slot_write = 0;
int g_slot_ready = 1;
int g_slot_display = 2;
int g_slot_ready_valid = 0;
int64_t g_last_frame_position = -1;

FlTextureRegistrar* g_texture_registrar = nullptr;
gint g_frame_notification_pending = 0;

void EnsureState() {
  std::call_once(g_init_once, []() {
    g_mutex_init(&g_engine_mutex);
    g_mutex_init(&g_frame_mutex);
    g_mutex_init(&g_texture_mutex);
  });
}

void EnsureFactory() {
  std::call_once(g_factory_once, []() {
    g_factory_ready = mlt_factory_init(nullptr) != nullptr;
  });
}

void SetErrorLocked(const char* message) {
  g_last_error = message == nullptr ? "" : message;
}

void ResetFrameStateLocked() {
  g_slot_write = 0;
  g_slot_ready = 1;
  g_slot_display = 2;
  g_slot_ready_valid = 0;
  g_last_frame_position = -1;
}

void ReleaseSlots() {
  EnsureState();
  g_mutex_lock(&g_frame_mutex);
  for (FrameSlot& slot : g_slots) {
    std::free(slot.data);
    slot.data = nullptr;
    slot.capacity = 0;
    slot.width = 0;
    slot.height = 0;
  }
  ResetFrameStateLocked();
  g_mutex_unlock(&g_frame_mutex);
}

void InvalidateFrames() {
  EnsureState();
  g_mutex_lock(&g_frame_mutex);
  g_last_frame_position = -1;
  g_mutex_unlock(&g_frame_mutex);
}

void CloseConsumerLocked() {
  if (g_consumer == nullptr) return;
  mlt_consumer_stop(g_consumer);
  mlt_consumer_close(g_consumer);
  g_consumer = nullptr;
}

void CloseMediaLocked() {
  CloseConsumerLocked();
  if (g_producer != nullptr) {
    mlt_producer_close(g_producer);
    g_producer = nullptr;
  }
  if (g_profile != nullptr) {
    mlt_profile_close(g_profile);
    g_profile = nullptr;
  }
  g_source_fps = 0.0;
  g_atomic_int_set(&g_target_width, 0);
  g_atomic_int_set(&g_target_height, 0);
}

void RefreshLocked() {
  if (g_consumer == nullptr) return;
  mlt_properties_set_int(
      MLT_CONSUMER_PROPERTIES(g_consumer),
      "refresh",
      1);
}

bool EnsureConsumerRunningLocked() {
  if (g_consumer == nullptr) return false;
  if (!mlt_consumer_is_stopped(g_consumer)) return true;

  // MLT consumers that stopped at EOF still need stop() once to join their
  // worker threads before they are restarted.
  mlt_consumer_stop(g_consumer);
  if (mlt_consumer_start(g_consumer) != 0) {
    SetErrorLocked("MLT could not restart the EDIT preview consumer.");
    return false;
  }
  return true;
}

void NotifyFlutterFrameAvailable();

void OnConsumerFrameShow(
    mlt_properties owner,
    void* listener_data,
    mlt_event_data event_data) {
  (void)owner;
  (void)listener_data;

  mlt_frame frame = mlt_event_data_to_frame(event_data);
  if (frame == nullptr) return;

  const int64_t position =
      static_cast<int64_t>(mlt_frame_get_position(frame));

  EnsureState();
  g_mutex_lock(&g_frame_mutex);
  const bool duplicate = position == g_last_frame_position;
  g_mutex_unlock(&g_frame_mutex);
  if (duplicate) return;

  mlt_image_format format = mlt_image_rgba;
  uint8_t* image = nullptr;
  int width = g_atomic_int_get(&g_target_width);
  int height = g_atomic_int_get(&g_target_height);
  if (width <= 0 || height <= 0) return;

  // The consumer was configured for RGBA, scaling and deinterlacing before it
  // started. As in MLT Player, this call should retrieve the already-rendered
  // image rather than moving the full decode pipeline onto this timing callback.
  const int image_error = mlt_frame_get_image(
      frame,
      &image,
      &format,
      &width,
      &height,
      0);
  if (image_error != 0 || image == nullptr || format != mlt_image_rgba ||
      width <= 0 || height <= 0) {
    return;
  }

  const int measured_size =
      mlt_image_format_size(format, width, height, nullptr);
  if (measured_size <= 0) return;
  const size_t required = static_cast<size_t>(measured_size);

  FrameSlot* slot = &g_slots[g_slot_write];
  if (required > slot->capacity) {
    uint8_t* replacement =
        static_cast<uint8_t*>(std::realloc(slot->data, required));
    if (replacement == nullptr) return;
    slot->data = replacement;
    slot->capacity = required;
  }

  std::memcpy(slot->data, image, required);
  slot->width = width;
  slot->height = height;

  g_mutex_lock(&g_frame_mutex);
  const int previous_ready = g_slot_ready;
  g_slot_ready = g_slot_write;
  g_slot_write = previous_ready;
  g_slot_ready_valid = 1;
  g_last_frame_position = position;
  g_mutex_unlock(&g_frame_mutex);

  NotifyFlutterFrameAvailable();
}

bool CreateConsumerLocked() {
  if (g_producer == nullptr || g_profile == nullptr) {
    SetErrorLocked("No EDIT preview producer is loaded.");
    return false;
  }
  if (g_consumer != nullptr) return true;

  g_consumer = mlt_factory_consumer(g_profile, "sdl2_audio", nullptr);
  if (g_consumer == nullptr) {
    SetErrorLocked("Could not create MLT sdl2_audio preview consumer.");
    return false;
  }

  mlt_properties properties = MLT_CONSUMER_PROPERTIES(g_consumer);
  mlt_properties_set_int(properties, "real_time", 1);
  mlt_properties_set_int(properties, "terminate_on_pause", 0);
  mlt_properties_set_int(properties, "scrub_audio", 0);

  // R3nder has its own audio authority. The MLT consumer remains muted and is
  // used here for its proven render scheduling and video callback behavior.
  mlt_properties_set_double(properties, "volume", 0.0);

  mlt_properties_set(properties, "rescale", "bilinear");
  mlt_properties_set(properties, "deinterlacer", kDeinterlacer);
  mlt_properties_set_int(properties, "top_field_first", -1);
  mlt_properties_set_int(properties, "progressive", 1);
  mlt_properties_set_int(properties, "video_off", 0);
  mlt_properties_set(properties, "mlt_image_format", "rgba");

  mlt_events_listen(
      properties,
      nullptr,
      "consumer-frame-show",
      reinterpret_cast<mlt_listener>(OnConsumerFrameShow));

  if (mlt_consumer_connect(
          g_consumer,
          MLT_PRODUCER_SERVICE(g_producer)) != 0) {
    mlt_consumer_close(g_consumer);
    g_consumer = nullptr;
    SetErrorLocked("MLT could not connect the EDIT preview consumer.");
    return false;
  }

  return true;
}

int ClampSourceFrameLocked(int64_t frame) {
  if (g_producer == nullptr) return 0;
  const mlt_position length = mlt_producer_get_length(g_producer);
  if (length <= 0) return 0;
  if (frame < 0) return 0;
  if (frame >= static_cast<int64_t>(length)) {
    return static_cast<int>(length - 1);
  }
  return static_cast<int>(frame);
}

// ---------------------------------------------------------------------------
// Flutter GL texture
// ---------------------------------------------------------------------------

typedef struct _R3EditPreviewTexture {
  FlTextureGL parent_instance;
  GLuint gl_texture_id;
  int uploaded_width;
  int uploaded_height;
} R3EditPreviewTexture;

typedef struct _R3EditPreviewTextureClass {
  FlTextureGLClass parent_class;
} R3EditPreviewTextureClass;

R3EditPreviewTexture* g_video_texture = nullptr;

G_DEFINE_TYPE(
    R3EditPreviewTexture,
    r3_edit_preview_texture,
    fl_texture_gl_get_type())

gboolean TextureFail(GError** error, const char* message) {
  if (error != nullptr && *error == nullptr) {
    g_set_error_literal(
        error,
        g_quark_from_static_string("r3nder-edit-preview-texture-error"),
        1,
        message == nullptr ? "EDIT preview texture is not ready." : message);
  }
  return FALSE;
}

gboolean PopulateTexture(
    FlTextureGL* texture,
    uint32_t* target,
    uint32_t* name,
    uint32_t* width,
    uint32_t* height,
    GError** error) {
  auto* self = reinterpret_cast<R3EditPreviewTexture*>(texture);
  EnsureState();

  g_mutex_lock(&g_frame_mutex);
  if (g_slot_ready_valid) {
    const int previous_display = g_slot_display;
    g_slot_display = g_slot_ready;
    g_slot_ready = previous_display;
    g_slot_ready_valid = 0;
  }
  const int display_index = g_slot_display;
  g_mutex_unlock(&g_frame_mutex);

  FrameSlot* slot = &g_slots[display_index];
  if (slot->data == nullptr || slot->width <= 0 || slot->height <= 0) {
    return TextureFail(error, "EDIT preview has not produced a frame yet.");
  }

  if (self->gl_texture_id == 0) {
    glGenTextures(1, &self->gl_texture_id);
    glBindTexture(GL_TEXTURE_2D, self->gl_texture_id);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  } else {
    glBindTexture(GL_TEXTURE_2D, self->gl_texture_id);
  }

  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  if (self->uploaded_width != slot->width ||
      self->uploaded_height != slot->height) {
    glTexImage2D(
        GL_TEXTURE_2D,
        0,
        GL_RGBA8,
        slot->width,
        slot->height,
        0,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        slot->data);
    self->uploaded_width = slot->width;
    self->uploaded_height = slot->height;
  } else {
    glTexSubImage2D(
        GL_TEXTURE_2D,
        0,
        0,
        0,
        slot->width,
        slot->height,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        slot->data);
  }

  *target = GL_TEXTURE_2D;
  *name = self->gl_texture_id;
  *width = static_cast<uint32_t>(slot->width);
  *height = static_cast<uint32_t>(slot->height);
  return TRUE;
}

void r3_edit_preview_texture_class_init(R3EditPreviewTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = PopulateTexture;
}

void r3_edit_preview_texture_init(R3EditPreviewTexture* self) {
  self->gl_texture_id = 0;
  self->uploaded_width = 0;
  self->uploaded_height = 0;
}

gboolean MarkFlutterTextureFrame(gpointer user_data) {
  (void)user_data;
  EnsureState();

  g_mutex_lock(&g_texture_mutex);
  FlTextureRegistrar* registrar = g_texture_registrar;
  R3EditPreviewTexture* texture = g_video_texture;
  if (registrar != nullptr && texture != nullptr) {
    g_object_ref(registrar);
    g_object_ref(texture);
  } else {
    registrar = nullptr;
    texture = nullptr;
  }
  g_mutex_unlock(&g_texture_mutex);

  if (registrar != nullptr && texture != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(
        registrar,
        FL_TEXTURE(texture));
    g_object_unref(texture);
    g_object_unref(registrar);
  }

  g_atomic_int_set(&g_frame_notification_pending, 0);
  return G_SOURCE_REMOVE;
}

void NotifyFlutterFrameAvailable() {
  if (g_atomic_int_compare_and_exchange(
          &g_frame_notification_pending,
          0,
          1)) {
    g_main_context_invoke(nullptr, MarkFlutterTextureFrame, nullptr);
  }
}

}  // namespace

extern "C" int64_t r3_edit_preview_register_flutter_texture(
    FlTextureRegistrar* registrar) {
  if (registrar == nullptr) return -1;
  EnsureState();

  g_mutex_lock(&g_texture_mutex);
  if (g_video_texture != nullptr && g_texture_registrar != nullptr) {
    const int64_t existing =
        fl_texture_get_id(FL_TEXTURE(g_video_texture));
    g_mutex_unlock(&g_texture_mutex);
    return existing;
  }

  FlTextureRegistrar* local_registrar =
      FL_TEXTURE_REGISTRAR(g_object_ref(registrar));
  auto* local_texture = reinterpret_cast<R3EditPreviewTexture*>(
      g_object_new(r3_edit_preview_texture_get_type(), nullptr));
  if (local_texture == nullptr) {
    g_object_unref(local_registrar);
    g_mutex_unlock(&g_texture_mutex);
    return -1;
  }

  if (!fl_texture_registrar_register_texture(
          local_registrar,
          FL_TEXTURE(local_texture))) {
    g_object_unref(local_texture);
    g_object_unref(local_registrar);
    g_mutex_unlock(&g_texture_mutex);
    return -1;
  }

  g_texture_registrar = local_registrar;
  g_video_texture = local_texture;
  const int64_t texture_id =
      fl_texture_get_id(FL_TEXTURE(g_video_texture));
  g_mutex_unlock(&g_texture_mutex);
  return texture_id;
}

extern "C" void r3_edit_preview_unregister_flutter_texture(void) {
  EnsureState();

  g_mutex_lock(&g_texture_mutex);
  FlTextureRegistrar* registrar = g_texture_registrar;
  R3EditPreviewTexture* texture = g_video_texture;
  g_texture_registrar = nullptr;
  g_video_texture = nullptr;
  g_mutex_unlock(&g_texture_mutex);

  if (registrar != nullptr && texture != nullptr) {
    fl_texture_registrar_unregister_texture(
        registrar,
        FL_TEXTURE(texture));
  }
  if (texture != nullptr) g_object_unref(texture);
  if (registrar != nullptr) g_object_unref(registrar);
}

extern "C" int64_t r3_edit_preview_texture_id(void) {
  EnsureState();
  g_mutex_lock(&g_texture_mutex);
  const int64_t texture_id = g_video_texture == nullptr
      ? -1
      : fl_texture_get_id(FL_TEXTURE(g_video_texture));
  g_mutex_unlock(&g_texture_mutex);
  return texture_id;
}

extern "C" int r3_edit_preview_open(
    const char* path,
    int width,
    int height) {
  EnsureState();
  EnsureFactory();
  if (!g_factory_ready || path == nullptr || path[0] == '\0') return 0;

  g_mutex_lock(&g_engine_mutex);
  CloseMediaLocked();

  g_profile = mlt_profile_init(nullptr);
  if (g_profile == nullptr) {
    SetErrorLocked("Could not create an MLT EDIT preview profile.");
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }

  mlt_producer probe = mlt_factory_producer(g_profile, nullptr, path);
  if (probe == nullptr) {
    SetErrorLocked("MLT could not probe the EDIT preview source.");
    CloseMediaLocked();
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }

  mlt_producer_probe(probe);
  mlt_profile_from_producer(g_profile, probe);
  mlt_producer_close(probe);

  g_producer = mlt_factory_producer(g_profile, nullptr, path);
  if (g_producer == nullptr) {
    SetErrorLocked("MLT could not reopen the EDIT preview source.");
    CloseMediaLocked();
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }
  mlt_producer_probe(g_producer);

  const mlt_position length = mlt_producer_get_length(g_producer);
  g_source_fps = mlt_producer_get_fps(g_producer);
  if (length <= 0 || g_source_fps <= 0.0) {
    SetErrorLocked("The EDIT preview source has invalid timing metadata.");
    CloseMediaLocked();
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }

  // Preserve the source-derived profile dimensions by default. That is the
  // path already proven in MLT Player to arrive pre-rendered at frame-show.
  // A caller may request smaller dimensions later once the texture path itself
  // is established, but an invalid request never overrides the profile.
  const int target_width = width > 0 ? width : g_profile->width;
  const int target_height = height > 0 ? height : g_profile->height;
  g_atomic_int_set(&g_target_width, target_width);
  g_atomic_int_set(&g_target_height, target_height);

  mlt_producer_set_speed(g_producer, 0.0);
  mlt_producer_seek(g_producer, 0);

  if (!CreateConsumerLocked()) {
    CloseMediaLocked();
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }
  if (mlt_consumer_start(g_consumer) != 0) {
    SetErrorLocked("MLT could not start the EDIT preview consumer.");
    CloseMediaLocked();
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }

  RefreshLocked();
  SetErrorLocked(nullptr);
  g_mutex_unlock(&g_engine_mutex);
  InvalidateFrames();
  return 1;
}

extern "C" void r3_edit_preview_close(void) {
  EnsureState();
  g_mutex_lock(&g_engine_mutex);
  CloseMediaLocked();
  g_mutex_unlock(&g_engine_mutex);
  ReleaseSlots();
}

extern "C" int r3_edit_preview_seek_frame(int64_t source_frame) {
  return r3_edit_preview_pause_at(source_frame);
}

extern "C" int r3_edit_preview_play_from(
    int64_t source_frame,
    int64_t project_fps_num,
    int64_t project_fps_den,
    int64_t speed_num,
    int64_t speed_den) {
  EnsureState();
  g_mutex_lock(&g_engine_mutex);

  if (g_producer == nullptr || g_consumer == nullptr ||
      project_fps_num <= 0 || project_fps_den <= 0 ||
      speed_num <= 0 || speed_den <= 0 || g_source_fps <= 0.0) {
    SetErrorLocked("Invalid EDIT preview playback request.");
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }

  const int frame = ClampSourceFrameLocked(source_frame);
  const double project_fps =
      static_cast<double>(project_fps_num) /
      static_cast<double>(project_fps_den);
  const double authored_speed =
      static_cast<double>(speed_num) /
      static_cast<double>(speed_den);
  const double mlt_speed =
      (project_fps * authored_speed) / g_source_fps;
  if (!std::isfinite(mlt_speed) || mlt_speed <= 0.0) {
    SetErrorLocked("Computed MLT EDIT preview speed is invalid.");
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }

  mlt_producer_set_speed(g_producer, 0.0);
  mlt_consumer_purge(g_consumer);
  mlt_producer_seek(g_producer, frame);
  mlt_producer_set_speed(g_producer, mlt_speed);

  if (!EnsureConsumerRunningLocked()) {
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }
  RefreshLocked();
  SetErrorLocked(nullptr);
  g_mutex_unlock(&g_engine_mutex);
  InvalidateFrames();
  return 1;
}

extern "C" int r3_edit_preview_pause_at(int64_t source_frame) {
  EnsureState();
  g_mutex_lock(&g_engine_mutex);

  if (g_producer == nullptr || g_consumer == nullptr) {
    SetErrorLocked("No EDIT preview source is open.");
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }

  const int frame = ClampSourceFrameLocked(source_frame);
  mlt_producer_set_speed(g_producer, 0.0);
  mlt_consumer_purge(g_consumer);
  mlt_producer_seek(g_producer, frame);

  if (!EnsureConsumerRunningLocked()) {
    g_mutex_unlock(&g_engine_mutex);
    return 0;
  }
  RefreshLocked();
  SetErrorLocked(nullptr);
  g_mutex_unlock(&g_engine_mutex);
  InvalidateFrames();
  return 1;
}

extern "C" int64_t r3_edit_preview_position_frame(void) {
  EnsureState();
  g_mutex_lock(&g_engine_mutex);
  int64_t position = -1;
  if (g_producer != nullptr) {
    if (g_consumer != nullptr && !mlt_consumer_is_stopped(g_consumer) &&
        mlt_producer_get_speed(g_producer) != 0.0) {
      position = static_cast<int64_t>(mlt_consumer_position(g_consumer));
    } else {
      position = static_cast<int64_t>(mlt_producer_position(g_producer));
    }
  }
  g_mutex_unlock(&g_engine_mutex);
  return position;
}

extern "C" double r3_edit_preview_source_fps(void) {
  EnsureState();
  g_mutex_lock(&g_engine_mutex);
  const double fps = g_source_fps;
  g_mutex_unlock(&g_engine_mutex);
  return fps;
}

extern "C" int r3_edit_preview_is_playing(void) {
  EnsureState();
  g_mutex_lock(&g_engine_mutex);
  const int playing =
      g_producer != nullptr && g_consumer != nullptr &&
      !mlt_consumer_is_stopped(g_consumer) &&
      mlt_producer_get_speed(g_producer) != 0.0;
  g_mutex_unlock(&g_engine_mutex);
  return playing;
}

extern "C" int r3_edit_preview_set_output_size(int width, int height) {
  if (width <= 0 || height <= 0) return 0;
  EnsureState();
  g_atomic_int_set(&g_target_width, width);
  g_atomic_int_set(&g_target_height, height);

  g_mutex_lock(&g_engine_mutex);
  RefreshLocked();
  g_mutex_unlock(&g_engine_mutex);
  InvalidateFrames();
  return 1;
}

extern "C" int r3_edit_preview_copy_last_error(
    char* buffer,
    int capacity) {
  EnsureState();
  g_mutex_lock(&g_engine_mutex);
  const int required = static_cast<int>(g_last_error.size()) + 1;
  if (buffer != nullptr && capacity > 0) {
    const int copy_count = std::min(
        static_cast<int>(g_last_error.size()),
        capacity - 1);
    if (copy_count > 0) {
      std::memcpy(buffer, g_last_error.data(), static_cast<size_t>(copy_count));
    }
    buffer[copy_count] = '\0';
  }
  g_mutex_unlock(&g_engine_mutex);
  return required;
}
