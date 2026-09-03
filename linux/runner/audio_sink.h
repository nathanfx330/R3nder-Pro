// ./linux/runner/audio_sink.h
#pragma once

#include <cstdint>

extern "C" {

struct R3AudioSinkStats {
  int64_t submitted_samples;
  int64_t latency_samples;
  int64_t queued_samples;
  int32_t sample_rate;
  int32_t channels;
  int32_t healthy;
  int32_t draining;
};

// Creates a PulseAudio-compatible playback sink for signed 16-bit little-endian
// interleaved PCM. The returned handle owns a worker thread. PCM enqueued from
// Dart is copied into a bounded native queue, so feeding audio never blocks the
// UI isolate on pa_simple_write().
void* r3_audio_sink_create(const char* device, int32_t sample_rate,
                           int32_t channels, int32_t latency_ms,
                           int32_t max_queue_ms);

void r3_audio_sink_destroy(void* handle);

// Copies one PCM chunk into the bounded native queue.
//   1  accepted
//   0  queue full; caller should retry later
//  -1  invalid handle, invalid/alignment-broken data, or sink failure
int32_t r3_audio_sink_enqueue(void* handle, const uint8_t* data,
                              int64_t byte_count);

// Requests natural audible drain after every already-accepted PCM packet. The
// worker performs pa_simple_drain(); Dart observes completion through the
// draining field in R3AudioSinkStats, so the UI isolate never waits inside FFI.
// Returns 1 when requested/already pending, -1 on sink failure.
int32_t r3_audio_sink_request_drain(void* handle);

// Drops queued and server-buffered audio while keeping the monotonic submitted
// sample counter intact. Returns 1 on success, -1 on sink failure.
int32_t r3_audio_sink_flush(void* handle);

// Returns a thread-local snapshot. Callers must consume its fields before the
// next r3_audio_sink_read() on the same native thread.
const R3AudioSinkStats* r3_audio_sink_read(void* handle);

// Copies the most recent sink error into [buffer], NUL terminated when capacity
// is positive. Returns the full error length, excluding the terminator.
int32_t r3_audio_sink_copy_last_error(void* handle, char* buffer,
                                      int32_t capacity);

// Same contract as above, for a failed create where no handle exists.
int32_t r3_audio_sink_copy_create_error(char* buffer, int32_t capacity);

}  // extern "C"
