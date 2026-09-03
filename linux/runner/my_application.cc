// ./linux/runner/my_application.cc

#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "edit_preview_texture.h"
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  // Native file bridge. It forwards OS drops to Dart and also accepts the
  // explicit pickVideo method from the EDIT workspace. Owned here; created in
  // activate and released in dispose.
  FlMethodChannel* drop_channel;

  // Last motion position forwarded to Dart, and whether one has been sent
  // during the current drag. See on_drag_motion for why this is filtered
  // here rather than in Dart.
  gint last_motion_x;
  gint last_motion_y;
  gboolean motion_sent;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  (void)self;

  // Flutter's external texture registrar is not reliably ready during early
  // runner construction. MLT Player solved this startup race by registering
  // its native video texture after Flutter has produced its first frame. Use
  // the same lifecycle here.
  FlEngine* engine = fl_view_get_engine(view);
  if (engine != nullptr) {
    FlTextureRegistrar* registrar = fl_engine_get_texture_registrar(engine);
    if (registrar == nullptr ||
        r3_edit_preview_register_flutter_texture(registrar) <= 0) {
      g_warning("R3nder: failed to register EDIT preview texture.");
    }
  } else {
    g_warning("R3nder: Flutter engine unavailable for EDIT preview texture.");
  }

  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// ---------------------------------------------------------------------------
// Dart -> GTK file chooser
// ---------------------------------------------------------------------------

static FlMethodResponse* pick_video(MyApplication* self) {
  GtkWindow* parent =
      gtk_application_get_active_window(GTK_APPLICATION(self));
  GtkWidget* dialog = gtk_file_chooser_dialog_new(
      "Add Video",
      parent,
      GTK_FILE_CHOOSER_ACTION_OPEN,
      "_Cancel",
      GTK_RESPONSE_CANCEL,
      "_Open",
      GTK_RESPONSE_ACCEPT,
      nullptr);

  GtkFileFilter* video_filter = gtk_file_filter_new();
  gtk_file_filter_set_name(video_filter, "Video files");
  gtk_file_filter_add_pattern(video_filter, "*.mp4");
  gtk_file_filter_add_pattern(video_filter, "*.MP4");
  gtk_file_filter_add_pattern(video_filter, "*.mov");
  gtk_file_filter_add_pattern(video_filter, "*.MOV");
  gtk_file_filter_add_pattern(video_filter, "*.mkv");
  gtk_file_filter_add_pattern(video_filter, "*.MKV");
  gtk_file_filter_add_pattern(video_filter, "*.webm");
  gtk_file_filter_add_pattern(video_filter, "*.WEBM");
  gtk_file_filter_add_pattern(video_filter, "*.m4v");
  gtk_file_filter_add_pattern(video_filter, "*.M4V");
  gtk_file_filter_add_pattern(video_filter, "*.avi");
  gtk_file_filter_add_pattern(video_filter, "*.AVI");
  gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), video_filter);

  GtkFileFilter* all_filter = gtk_file_filter_new();
  gtk_file_filter_set_name(all_filter, "All files");
  gtk_file_filter_add_pattern(all_filter, "*");
  gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), all_filter);

  g_autofree gchar* filename = nullptr;
  if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
    filename = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
  }
  gtk_widget_destroy(dialog);

  g_autoptr(FlValue) result = filename == nullptr
      ? fl_value_new_null()
      : fl_value_new_string(filename);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void native_file_method_call_handler(FlMethodChannel* channel,
                                            FlMethodCall* method_call,
                                            gpointer user_data) {
  (void)channel;
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(fl_method_call_get_name(method_call), "pickVideo") == 0) {
    response = pick_video(self);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send native file response: %s", error->message);
  }
}

// ---------------------------------------------------------------------------
// OS drag-and-drop -> Dart bridge
//
// The Flutter view is registered as a GTK drag destination for text/uri-list
// (the MIME type file managers use for file drags). On drop, each URI is
// converted to a filesystem path and the batch is sent to Dart over the
// "r3nder/drop" method channel as method "onDrop".
//
// PAYLOAD: a map, not a bare list.
//
//   { "paths": [ "/abs/path", ... ], "x": <double>, "y": <double> }
//
// The position is what lets Dart hit-test the drop against a widget instead
// of requiring the UI to nominate a destination beforehand. It used to be a
// bare list of paths, which is why Dart still accepts that shape: the C side
// needs a full rebuild while Dart hot-reloads, so the two halves are
// routinely out of step during development and neither should hard-fail on
// the other.
//
// COORDINATE SPACE: x and y arrive from GTK in FlView widget coordinates,
// which are Flutter's logical pixels 1:1. The Linux embedder sends window
// metrics as (allocation * scale_factor) with devicePixelRatio = scale_factor,
// so Flutter's logical size is the widget allocation and the origins coincide.
// Nothing to convert, and no scale factor worth sending: if a fractional
// scaling setup ever breaks that assumption, a wrong number in the payload
// would hide the problem rather than expose it.
//
// Dart-side listeners decide what to do with the paths; drops arriving while
// no listener cares are simply ignored.
//
// THREE EVENT METHODS on this channel. "onDrop" is the commit and the only
// one that matters for correctness. "onDragMotion" and "onDragLeave" are
// hover feedback and are purely advisory: ignoring them costs the highlight,
// not the import. The same channel also accepts the Dart initiated pickVideo
// request handled above.
// ---------------------------------------------------------------------------

// Pixels the pointer must travel before another motion event is forwarded.
// Small enough that a target boundary is never missed by a meaningful
// margin, large enough that a slow drag across one field does not flood the
// channel. See on_drag_motion.
static const gint kMotionThresholdPx = 4;

// Fired continuously while a drag hovers the view, so that Dart can
// highlight the field under the cursor before the user commits.
//
// WHY THIS IS THROTTLED HERE. Filtering happens in two stages, split by
// which side knows what. This side cannot know which widget is under the
// cursor: the geometry only exists in Dart. So it filters on the one thing
// it does know, movement, and forwards only when the pointer has actually
// travelled. Dart then resolves the position to a field and repaints only
// when that field changes. A drag crossing 200 pixels inside one field
// therefore costs a handful of channel messages and one repaint, instead of
// one message and one hit test per motion event at pointer frequency.
//
// The filter is stateless and cannot make a wrong decision: its worst case
// is forwarding one event more than strictly needed.
//
// Returns FALSE so GTK's default handler still runs. The view was
// registered with GTK_DEST_DEFAULT_ALL, which is what calls gdk_drag_status
// and keeps the drag cursor correct; taking that over here would mean
// reimplementing it.
static gboolean on_drag_motion(GtkWidget* widget,
                               GdkDragContext* context,
                               gint x,
                               gint y,
                               guint time,
                               gpointer user_data) {
  (void)widget;
  (void)context;
  (void)time;
  MyApplication* self = MY_APPLICATION(user_data);

  if (self->drop_channel != nullptr) {
    gint dx = x - self->last_motion_x;
    gint dy = y - self->last_motion_y;
    if (dx < 0) dx = -dx;
    if (dy < 0) dy = -dy;

    if (!self->motion_sent || dx >= kMotionThresholdPx ||
        dy >= kMotionThresholdPx) {
      self->last_motion_x = x;
      self->last_motion_y = y;
      self->motion_sent = TRUE;

      g_autoptr(FlValue) payload = fl_value_new_map();
      fl_value_set_string_take(payload, "x",
                               fl_value_new_float(static_cast<double>(x)));
      fl_value_set_string_take(payload, "y",
                               fl_value_new_float(static_cast<double>(y)));
      fl_method_channel_invoke_method(self->drop_channel, "onDragMotion",
                                      payload, nullptr, nullptr, nullptr);
    }
  }

  return FALSE;
}

// The drag left the view without dropping. Dart clears its highlight.
//
// GTK also emits this immediately before a successful drop, so Dart must
// treat leave as "no target" rather than as "cancelled", and must not
// depend on ordering between this and onDrop.
static void on_drag_leave(GtkWidget* widget,
                          GdkDragContext* context,
                          guint time,
                          gpointer user_data) {
  (void)widget;
  (void)context;
  (void)time;
  MyApplication* self = MY_APPLICATION(user_data);
  self->motion_sent = FALSE;

  if (self->drop_channel != nullptr) {
    fl_method_channel_invoke_method(self->drop_channel, "onDragLeave", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

static void on_drag_data_received(GtkWidget* widget,
                                  GdkDragContext* context,
                                  gint x,
                                  gint y,
                                  GtkSelectionData* data,
                                  guint info,
                                  guint time,
                                  gpointer user_data) {
  (void)widget;
  (void)info;
  MyApplication* self = MY_APPLICATION(user_data);

  // The drag is over either way. Clearing here means the next drag always
  // forwards its first motion event rather than comparing against a stale
  // position from the previous one.
  self->motion_sent = FALSE;

  gboolean success = FALSE;

  if (self->drop_channel != nullptr &&
      gtk_selection_data_get_length(data) >= 0) {
    g_auto(GStrv) uris = gtk_selection_data_get_uris(data);
    if (uris != nullptr) {
      // Built unmanaged: ownership transfers into the payload map below via
      // fl_value_set_string_take, and is released by hand on the empty path.
      FlValue* paths = fl_value_new_list();
      for (int i = 0; uris[i] != nullptr; i++) {
        g_autofree gchar* path =
            g_filename_from_uri(uris[i], nullptr, nullptr);
        if (path != nullptr) {
          fl_value_append_take(paths, fl_value_new_string(path));
        }
      }

      if (fl_value_get_length(paths) > 0) {
        g_autoptr(FlValue) payload = fl_value_new_map();
        fl_value_set_string_take(payload, "paths", paths);
        fl_value_set_string_take(payload, "x",
                                 fl_value_new_float(static_cast<double>(x)));
        fl_value_set_string_take(payload, "y",
                                 fl_value_new_float(static_cast<double>(y)));

        fl_method_channel_invoke_method(self->drop_channel, "onDrop", payload,
                                        nullptr, nullptr, nullptr);
        success = TRUE;
      } else {
        fl_value_unref(paths);
      }
    }
  }

  gtk_drag_finish(context, success, FALSE, time);
}

static void setup_drop_target(MyApplication* self, FlView* view) {
  // Accept URI lists dropped anywhere on the Flutter view.
  GtkTargetEntry targets[] = {
      {const_cast<gchar*>("text/uri-list"), 0, 0},
  };
  gtk_drag_dest_set(GTK_WIDGET(view), GTK_DEST_DEFAULT_ALL, targets,
                    G_N_ELEMENTS(targets), GDK_ACTION_COPY);

  g_signal_connect(GTK_WIDGET(view), "drag-data-received",
                   G_CALLBACK(on_drag_data_received), self);

  // Hover feedback. Separate signals from the drop itself, and both are
  // advisory: if a build of Dart ignores them, dropping still works exactly
  // as before.
  g_signal_connect(GTK_WIDGET(view), "drag-motion",
                   G_CALLBACK(on_drag_motion), self);
  g_signal_connect(GTK_WIDGET(view), "drag-leave",
                   G_CALLBACK(on_drag_leave), self);

  // Standard codec, so both native events and Dart requests share one small
  // bridge without a plugin dependency.
  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->drop_channel = fl_method_channel_new(messenger, "r3nder/drop",
                                             FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->drop_channel,
      native_file_method_call_handler,
      self,
      nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "r3nder");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "r3nder");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // OS file drag-and-drop plus the explicit GTK video chooser. Must run after
  // realize so the engine and its binary messenger exist.
  setup_drop_target(self, view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                   gchar*** arguments,
                                                   int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // The external texture must be detached before Flutter destroys its texture
  // registrar. Stop MLT first so no consumer callback can publish another
  // frame while the registrar is disappearing.
  r3_edit_preview_close();
  r3_edit_preview_unregister_flutter_texture();

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->drop_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  // GObject zeroes the instance struct, so these are already correct. Stated
  // anyway because motion_sent being FALSE on the first drag is a
  // correctness requirement, not a convenience, and implicit zeroing is a
  // fragile thing to rest that on once someone adds a field whose default
  // is not zero.
  self->last_motion_x = 0;
  self->last_motion_y = 0;
  self->motion_sent = FALSE;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
