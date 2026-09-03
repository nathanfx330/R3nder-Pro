// ./linux/runner/project_clock.h
#pragma once

#include <cstdint>

extern "C" {

struct R3ClockSnapshot {
  int64_t frame;
  int64_t phase_num;
  int64_t phase_den;
  uint64_t epoch;
  int32_t mode;
  int32_t padding;
};

void* r3_clock_create(int64_t fps_num, int64_t fps_den);
void r3_clock_destroy(void* handle);

void r3_clock_set_rate(void* handle, int64_t fps_num, int64_t fps_den);
void r3_clock_seek_monotonic(void* handle, int64_t frame,
                             int64_t phase_num, int64_t phase_den);
void r3_clock_seek_scrub(void* handle, int64_t frame, int64_t phase_num,
                         int64_t phase_den);
void r3_clock_seek_audio(void* handle, int64_t frame, int64_t phase_num,
                         int64_t phase_den, int64_t origin_sample,
                         int64_t sample_rate, int64_t latency_samples);
void r3_clock_set_latency_samples(void* handle, int64_t latency_samples);
void r3_clock_set_played_samples(void* handle, int64_t played_samples);
void r3_clock_add_played_samples(void* handle, int64_t samples);
int64_t r3_clock_get_played_samples(void* handle);

// R3nder owns one realtime native preview clock. The audio sink reads this
// pointer so its worker can update the audio sample clock without routing
// cadence through Dart. Audio sinks must be destroyed before the clock.
void* r3_clock_active_handle();

const R3ClockSnapshot* r3_clock_read(void* handle);

}  // extern "C"
