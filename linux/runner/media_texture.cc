// ./linux/runner/media_texture.cc
//
// Flutter external texture presentation for the persistent MLT decoder worker.
//
// This is deliberately not an MLT consumer. ProjectClock still chooses every
// source frame and r3_media_decoder_request() still drives decode. The worker's
// exact-target sink copies completed RGBA into a small native rotation, then
// Flutter's raster thread uploads the newest slot into a double-buffered GL
// texture. No video pixels cross into Dart.

#include "media_texture.h"

#include "media_decoder.h"

#include <epoxy/gl.h>
#include <glib.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace {

constexpr int kFrameSlotCount = 3;

struct FrameSlot {
  std::vector<uint8_t> rgba;
  int32_t width = 0;
  int32_t height = 0;
  int32_t stride = 0;
  int64_t requested_frame = -1;
};

typedef struct _R3MediaTexture {
  FlTextureGL parent_instance;
  GLuint gl_texture_ids[2];
  int uploaded_width[2];
  int uploaded_height[2];
  int front_texture_index;
} R3MediaTexture;

typedef struct _R3MediaTextureClass {
  FlTextureGLClass parent_class;
} R3MediaTextureClass;

std::mutex g_texture_mutex;
FlTextureRegistrar* g_texture_registrar = nullptr;
R3MediaTexture* g_video_texture = nullptr;
std::atomic<int> g_frame_notification_pending{0};

FrameSlot g_slots[kFrameSlotCount];
int g_slot_write = 0;
int g_slot_ready = 1;
int g_slot_display = 2;
bool g_slot_ready_valid = false;

void* g_active_decoder = nullptr;
int64_t g_requested_frame = -1;
int32_t g_requested_width = 0;
int32_t g_requested_height = 0;

void* g_last_published_decoder = nullptr;
int64_t g_last_published_frame = -1;
int32_t g_last_published_width = 0;
int32_t g_last_published_height = 0;

static gboolean R3MediaTexturePopulate(
    FlTextureGL* texture,
    uint32_t* target,
    uint32_t* name,
    uint32_t* width,
    uint32_t* height,
    GError** error);

static void r3_media_texture_class_init(R3MediaTextureClass* klass);
static void r3_media_texture_init(R3MediaTexture* self);

G_DEFINE_TYPE(R3MediaTexture, r3_media_texture, fl_texture_gl_get_type())

bool FailTexture(GError** error, const char* message) {
  if (error != nullptr && *error == nullptr) {
    g_set_error_literal(
        error,
        g_quark_from_static_string("r3nder-media-texture-error"),
        1,
        message == nullptr ? "R3nder media texture is not ready." : message);
  }
  return false;
}

void ConfigureTexture(GLuint texture_id) {
  glBindTexture(GL_TEXTURE_2D, texture_id);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

static gboolean MarkFlutterTextureFrame(gpointer user_data) {
  (void)user_data;

  FlTextureRegistrar* registrar = nullptr;
  R3MediaTexture* texture = nullptr;

  {
    std::lock_guard<std::mutex> lock(g_texture_mutex);
    if (g_texture_registrar != nullptr && g_video_texture != nullptr) {
      registrar = FL_TEXTURE_REGISTRAR(g_object_ref(g_texture_registrar));
      texture = static_cast<R3MediaTexture*>(
          g_object_ref(g_video_texture));
    }
  }

  if (registrar != nullptr && texture != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(
        registrar,
        FL_TEXTURE(texture));
    g_object_unref(texture);
    g_object_unref(registrar);
  }

  g_frame_notification_pending.store(0, std::memory_order_release);
  return G_SOURCE_REMOVE;
}

void NotifyFlutterFrameAvailable() {
  int expected = 0;
  if (g_frame_notification_pending.compare_exchange_strong(
          expected,
          1,
          std::memory_order_acq_rel)) {
    g_main_context_invoke(nullptr, MarkFlutterTextureFrame, nullptr);
  }
}

void PublishTextureFrame(
    void* decoder_handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height,
    int32_t stride,
    const uint8_t* rgba,
    int64_t byte_length) {
  if (decoder_handle == nullptr || rgba == nullptr ||
      requested_frame < 0 || width <= 0 || height <= 0 || stride <= 0 ||
      byte_length <= 0) {
    return;
  }

  const int32_t packed_stride = width * 4;
  if (packed_stride <= 0 || stride < packed_stride) return;
  const int64_t packed_length =
      static_cast<int64_t>(packed_stride) * static_cast<int64_t>(height);
  const int64_t source_required =
      static_cast<int64_t>(stride) * static_cast<int64_t>(height);
  if (packed_length <= 0 || source_required > byte_length) return;

  bool published = false;
  {
    std::lock_guard<std::mutex> lock(g_texture_mutex);

    if (g_texture_registrar == nullptr || g_video_texture == nullptr ||
        decoder_handle != g_active_decoder ||
        requested_frame != g_requested_frame ||
        width != g_requested_width || height != g_requested_height) {
      return;
    }

    // Rate-conformed 24 fps media in a 30 fps project intentionally maps some
    // adjacent project frames to the same source frame. Do not upload identical
    // source pixels twice just because ProjectClock advanced.
    if (decoder_handle == g_last_published_decoder &&
        requested_frame == g_last_published_frame &&
        width == g_last_published_width &&
        height == g_last_published_height) {
      return;
    }

    FrameSlot& slot = g_slots[g_slot_write];
    slot.rgba.resize(static_cast<std::size_t>(packed_length));

    if (stride == packed_stride) {
      std::memcpy(
          slot.rgba.data(),
          rgba,
          static_cast<std::size_t>(packed_length));
    } else {
      for (int32_t row = 0; row < height; ++row) {
        std::memcpy(
            slot.rgba.data() +
                static_cast<std::size_t>(row) * packed_stride,
            rgba + static_cast<std::size_t>(row) * stride,
            static_cast<std::size_t>(packed_stride));
      }
    }

    slot.width = width;
    slot.height = height;
    slot.stride = packed_stride;
    slot.requested_frame = requested_frame;

    const int previous_ready = g_slot_ready;
    g_slot_ready = g_slot_write;
    g_slot_write = previous_ready;
    g_slot_ready_valid = true;

    g_last_published_decoder = decoder_handle;
    g_last_published_frame = requested_frame;
    g_last_published_width = width;
    g_last_published_height = height;
    published = true;
  }

  if (published) NotifyFlutterFrameAvailable();
}

void DecoderFrameSink(
    void* decoder_handle,
    int64_t requested_frame,
    int64_t actual_frame,
    int32_t width,
    int32_t height,
    int32_t stride,
    const uint8_t* rgba,
    int64_t byte_length,
    void* user_data) {
  (void)actual_frame;
  (void)user_data;
  PublishTextureFrame(
      decoder_handle,
      requested_frame,
      width,
      height,
      stride,
      rgba,
      byte_length);
}

static gboolean R3MediaTexturePopulate(
    FlTextureGL* texture,
    uint32_t* target,
    uint32_t* name,
    uint32_t* width,
    uint32_t* height,
    GError** error) {
  R3MediaTexture* self = reinterpret_cast<R3MediaTexture*>(texture);

  int display_index = -1;
  bool consumed_ready_frame = false;

  {
    std::lock_guard<std::mutex> lock(g_texture_mutex);
    if (g_slot_ready_valid) {
      const int previous_display = g_slot_display;
      g_slot_display = g_slot_ready;
      g_slot_ready = previous_display;
      g_slot_ready_valid = false;
      consumed_ready_frame = true;
    }
    display_index = g_slot_display;
  }

  FrameSlot& slot = g_slots[display_index];
  if (slot.rgba.empty() || slot.width <= 0 || slot.height <= 0) {
    return FailTexture(error, "R3nder media texture has no decoded frame yet.");
  }

  int upload_index = self->front_texture_index;
  if (consumed_ready_frame) {
    upload_index =
        self->front_texture_index < 0 ? 0 : 1 - self->front_texture_index;
  } else if (self->front_texture_index < 0) {
    return FailTexture(error, "R3nder media texture has no uploaded front frame.");
  }

  if (consumed_ready_frame) {
    if (self->gl_texture_ids[upload_index] == 0) {
      glGenTextures(1, &self->gl_texture_ids[upload_index]);
      ConfigureTexture(self->gl_texture_ids[upload_index]);
    } else {
      glBindTexture(GL_TEXTURE_2D, self->gl_texture_ids[upload_index]);
    }

    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

    if (self->uploaded_width[upload_index] != slot.width ||
        self->uploaded_height[upload_index] != slot.height) {
      glTexImage2D(
          GL_TEXTURE_2D,
          0,
          GL_RGBA8,
          slot.width,
          slot.height,
          0,
          GL_RGBA,
          GL_UNSIGNED_BYTE,
          slot.rgba.data());
      self->uploaded_width[upload_index] = slot.width;
      self->uploaded_height[upload_index] = slot.height;
    } else {
      glTexSubImage2D(
          GL_TEXTURE_2D,
          0,
          0,
          0,
          slot.width,
          slot.height,
          GL_RGBA,
          GL_UNSIGNED_BYTE,
          slot.rgba.data());
    }

    self->front_texture_index = upload_index;
  }

  const int front_index = self->front_texture_index;
  if (front_index < 0 || self->gl_texture_ids[front_index] == 0 ||
      self->uploaded_width[front_index] <= 0 ||
      self->uploaded_height[front_index] <= 0) {
    return FailTexture(error, "R3nder media texture front buffer is invalid.");
  }

  *target = GL_TEXTURE_2D;
  *name = self->gl_texture_ids[front_index];
  *width = static_cast<uint32_t>(self->uploaded_width[front_index]);
  *height = static_cast<uint32_t>(self->uploaded_height[front_index]);
  return TRUE;
}

static void r3_media_texture_class_init(R3MediaTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = R3MediaTexturePopulate;
}

static void r3_media_texture_init(R3MediaTexture* self) {
  self->gl_texture_ids[0] = 0;
  self->gl_texture_ids[1] = 0;
  self->uploaded_width[0] = 0;
  self->uploaded_width[1] = 0;
  self->uploaded_height[0] = 0;
  self->uploaded_height[1] = 0;
  self->front_texture_index = -1;
}

}  // namespace

extern "C" int64_t r3_media_texture_register_flutter_texture(
    FlTextureRegistrar* registrar) {
  if (registrar == nullptr) return -1;

  std::lock_guard<std::mutex> lock(g_texture_mutex);
  if (g_video_texture != nullptr && g_texture_registrar != nullptr) {
    return fl_texture_get_id(FL_TEXTURE(g_video_texture));
  }

  FlTextureRegistrar* local_registrar =
      FL_TEXTURE_REGISTRAR(g_object_ref(registrar));
  R3MediaTexture* local_texture = static_cast<R3MediaTexture*>(
      g_object_new(r3_media_texture_get_type(), nullptr));

  if (local_texture == nullptr) {
    g_object_unref(local_registrar);
    return -1;
  }

  if (!fl_texture_registrar_register_texture(
          local_registrar,
          FL_TEXTURE(local_texture))) {
    g_object_unref(local_texture);
    g_object_unref(local_registrar);
    return -1;
  }

  g_texture_registrar = local_registrar;
  g_video_texture = local_texture;
  return fl_texture_get_id(FL_TEXTURE(g_video_texture));
}

extern "C" void r3_media_texture_unregister_flutter_texture(void) {
  FlTextureRegistrar* registrar = nullptr;
  R3MediaTexture* texture = nullptr;
  void* active_decoder = nullptr;

  {
    std::lock_guard<std::mutex> lock(g_texture_mutex);
    registrar = g_texture_registrar;
    texture = g_video_texture;
    active_decoder = g_active_decoder;

    g_texture_registrar = nullptr;
    g_video_texture = nullptr;
    g_active_decoder = nullptr;
    g_requested_frame = -1;
    g_requested_width = 0;
    g_requested_height = 0;
    g_slot_ready_valid = false;
    g_last_published_decoder = nullptr;
    g_last_published_frame = -1;
    g_last_published_width = 0;
    g_last_published_height = 0;
  }

  if (active_decoder != nullptr) {
    r3_media_decoder_set_frame_sink(active_decoder, nullptr, nullptr);
  }

  if (registrar != nullptr && texture != nullptr) {
    fl_texture_registrar_unregister_texture(registrar, FL_TEXTURE(texture));
  }
  if (texture != nullptr) g_object_unref(texture);
  if (registrar != nullptr) g_object_unref(registrar);

  g_frame_notification_pending.store(0, std::memory_order_release);
}

extern "C" int64_t r3_media_texture_id(void) {
  std::lock_guard<std::mutex> lock(g_texture_mutex);
  if (g_video_texture == nullptr || g_texture_registrar == nullptr) return -1;
  return fl_texture_get_id(FL_TEXTURE(g_video_texture));
}

extern "C" int r3_media_texture_request(
    void* decoder_handle,
    int64_t requested_frame,
    int32_t width,
    int32_t height) {
  if (decoder_handle == nullptr || requested_frame < 0 ||
      width <= 0 || height <= 0) {
    return -1;
  }

  bool bind_sink = false;
  {
    std::lock_guard<std::mutex> lock(g_texture_mutex);
    if (g_video_texture == nullptr || g_texture_registrar == nullptr) {
      return -1;
    }

    bind_sink = g_active_decoder != decoder_handle;
    g_active_decoder = decoder_handle;
    g_requested_frame = requested_frame;
    g_requested_width = width;
    g_requested_height = height;
  }

  if (bind_sink &&
      r3_media_decoder_set_frame_sink(
          decoder_handle,
          DecoderFrameSink,
          nullptr) != 0) {
    std::lock_guard<std::mutex> lock(g_texture_mutex);
    if (g_active_decoder == decoder_handle) {
      g_active_decoder = nullptr;
      g_requested_frame = -1;
      g_requested_width = 0;
      g_requested_height = 0;
    }
    return -1;
  }

  return r3_media_decoder_request(
      decoder_handle,
      requested_frame,
      width,
      height);
}

extern "C" void r3_media_texture_detach_decoder(void* decoder_handle) {
  if (decoder_handle == nullptr) return;

  r3_media_decoder_set_frame_sink(decoder_handle, nullptr, nullptr);

  std::lock_guard<std::mutex> lock(g_texture_mutex);
  if (g_active_decoder == decoder_handle) {
    g_active_decoder = nullptr;
    g_requested_frame = -1;
    g_requested_width = 0;
    g_requested_height = 0;
  }
  if (g_last_published_decoder == decoder_handle) {
    g_last_published_decoder = nullptr;
    g_last_published_frame = -1;
    g_last_published_width = 0;
    g_last_published_height = 0;
  }
}
