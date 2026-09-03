// ./linux/runner/project_clock_test.cc
//
// Standalone black-box regression tests for project_clock.cc.
// Compiled and run by test/project_clock_native_test.dart on Linux.

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <thread>

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
void r3_clock_seek_scrub(void* handle, int64_t frame, int64_t phase_num,
                         int64_t phase_den);
void r3_clock_seek_audio(void* handle, int64_t frame, int64_t phase_num,
                         int64_t phase_den, int64_t origin_sample,
                         int64_t sample_rate, int64_t latency_samples);
void r3_clock_set_latency_samples(void* handle, int64_t latency_samples);
void r3_clock_set_played_samples(void* handle, int64_t played_samples);
const R3ClockSnapshot* r3_clock_read(void* handle);

}  // extern "C"

namespace {

constexpr int32_t kScrub = 1;
constexpr int32_t kAudio = 2;

[[noreturn]] void Fail(const char* message) {
  std::cerr << "project_clock_test: " << message << '\n';
  std::exit(1);
}

void Require(bool condition, const char* message) {
  if (!condition) Fail(message);
}

bool IsTupleA(const R3ClockSnapshot& s) {
  return s.mode == kScrub && s.frame == 100 && s.phase_num == 1 &&
         s.phase_den == 7;
}

bool IsTupleB(const R3ClockSnapshot& s) {
  return s.mode == kScrub && s.frame == 200 && s.phase_num == 2 &&
         s.phase_den == 9;
}

}  // namespace

int main() {
  void* clock = r3_clock_create(30, 1);
  Require(clock != nullptr, "create failed");

  r3_clock_seek_scrub(clock, 10, 1, 2);
  R3ClockSnapshot s = *r3_clock_read(clock);
  Require(s.mode == kScrub, "scrub mode not reported");
  Require(s.frame == 10 && s.phase_num == 1 && s.phase_den == 2,
          "scrub position changed");
  Require(s.epoch == 1, "first seek did not advance epoch once");

  // A raw native rate write must not disturb a held scrub position.
  r3_clock_set_rate(clock, 24, 1);
  s = *r3_clock_read(clock);
  Require(s.frame == 10 && s.phase_num == 1 && s.phase_den == 2,
          "rate write disturbed held scrub position");

  // Restore 30 fps, then prove audio uses the monotonic played-sample counter
  // and subtracts both origin and latency without resetting that counter.
  r3_clock_set_rate(clock, 30, 1);
  r3_clock_set_played_samples(clock, 53800);
  r3_clock_seek_audio(clock, 5, 1, 2, 1000, 48000, 4800);
  s = *r3_clock_read(clock);
  Require(s.mode == kAudio, "audio mode not reported");
  Require(s.frame == 35 && s.phase_num == 1 && s.phase_den == 2,
          "audio sample origin arithmetic is wrong");

  // Measured latency can rise from one query to the next. That measurement
  // must never make AUDIO ProjectTime run backward.
  r3_clock_set_latency_samples(clock, 9600);
  s = *r3_clock_read(clock);
  Require(s.frame == 35 && s.phase_num == 1 && s.phase_den == 2,
          "audio clock rewound when measured latency increased");

  // A lower latency measurement may advance audible time normally.
  r3_clock_set_latency_samples(clock, 2400);
  s = *r3_clock_read(clock);
  Require(s.frame == 37 && s.phase_num == 0 && s.phase_den == 1,
          "audio clock did not advance when audible sample position advanced");

  // A later latency spike is clamped at that new audible high-water mark.
  r3_clock_set_latency_samples(clock, 7200);
  s = *r3_clock_read(clock);
  Require(s.frame == 37 && s.phase_num == 0 && s.phase_den == 1,
          "audio clock rewound after establishing a later audible floor");

  // Once cumulative playback moves beyond the floor, AUDIO time advances
  // again even with the higher latency measurement still in force.
  r3_clock_set_played_samples(clock, 60200);
  s = *r3_clock_read(clock);
  Require(s.frame == 38 && s.phase_num == 0 && s.phase_den == 1,
          "audio clock did not resume after playback passed the clamp floor");

  // The control seqlock is intentionally multi-reader but must be
  // single-writer. Two writers race here while this thread continuously
  // reads. Every accepted snapshot must be exactly one complete authored
  // tuple, never a mixture of fields from the two writers.
  r3_clock_seek_scrub(clock, 100, 1, 7);

  std::atomic<bool> go{false};
  std::atomic<int> ready{0};

  auto writer_a = std::thread([&]() {
    ready.fetch_add(1, std::memory_order_release);
    while (!go.load(std::memory_order_acquire)) {
    }
    for (int i = 0; i < 50000; ++i) {
      r3_clock_seek_scrub(clock, 100, 1, 7);
    }
  });

  auto writer_b = std::thread([&]() {
    ready.fetch_add(1, std::memory_order_release);
    while (!go.load(std::memory_order_acquire)) {
    }
    for (int i = 0; i < 50000; ++i) {
      r3_clock_seek_scrub(clock, 200, 2, 9);
    }
  });

  while (ready.load(std::memory_order_acquire) != 2) {
  }
  go.store(true, std::memory_order_release);

  for (int i = 0; i < 200000; ++i) {
    s = *r3_clock_read(clock);
    if (!IsTupleA(s) && !IsTupleB(s)) {
      Fail("reader accepted a mixed control snapshot");
    }
  }

  writer_a.join();
  writer_b.join();

  r3_clock_destroy(clock);
  std::cout << "project_clock_test: PASS\n";
  return 0;
}
