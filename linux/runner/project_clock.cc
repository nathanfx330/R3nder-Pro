// ./linux/runner/project_clock.cc
//
// Native realtime project clock for R3nder Pro.
//
// Control values are individual atomics and are grouped by a seqlock so a
// reader sees one coherent configuration (mode, epoch, origin, rate, latency)
// rather than a mixture from two writes. played_samples is intentionally NOT
// in that group: the eventual audio callback/sink owns it and updates that
// single counter independently at audio cadence.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <mutex>

namespace {

enum ClockMode : int32_t {
  kMonotonic = 0,
  kScrub = 1,
  kAudio = 2,
};

struct ClockState {
  // Seqlocks require one writer at a time. Control writes are rare, so a
  // mutex on the write side is effectively free and lets reads stay lock-free.
  // played_samples deliberately remains outside both the mutex and seqlock.
  std::mutex write_mutex;
  std::atomic<uint32_t> seq{0};

  std::atomic<int32_t> mode{kMonotonic};
  std::atomic<uint64_t> epoch{0};
  std::atomic<int64_t> base_frame{0};
  std::atomic<int64_t> base_phase_num{0};
  std::atomic<int64_t> base_phase_den{1};
  std::atomic<int64_t> origin_monotonic_ns{0};
  std::atomic<int64_t> origin_sample{0};
  std::atomic<int64_t> latency_samples{0};
  std::atomic<int64_t> sample_rate{48000};
  std::atomic<int64_t> fps_num{30};
  std::atomic<int64_t> fps_den{1};

  // Separate by design. The audio sink may write this without entering the
  // control seqlock; readers combine it with one coherent control snapshot.
  std::atomic<int64_t> played_samples{0};
};

struct ControlSnapshot {
  int32_t mode;
  uint64_t epoch;
  int64_t base_frame;
  int64_t base_phase_num;
  int64_t base_phase_den;
  int64_t origin_monotonic_ns;
  int64_t origin_sample;
  int64_t latency_samples;
  int64_t sample_rate;
  int64_t fps_num;
  int64_t fps_den;
};

int64_t MonotonicNs() {
  using namespace std::chrono;
  return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch())
      .count();
}

class ControlWriteGuard {
 public:
  explicit ControlWriteGuard(ClockState* clock)
      : clock_(clock), lock_(clock->write_mutex) {
    clock_->seq.fetch_add(1u, std::memory_order_acq_rel);
  }

  ~ControlWriteGuard() {
    clock_->seq.fetch_add(1u, std::memory_order_release);
  }

  ControlWriteGuard(const ControlWriteGuard&) = delete;
  ControlWriteGuard& operator=(const ControlWriteGuard&) = delete;

 private:
  ClockState* clock_;
  std::lock_guard<std::mutex> lock_;
};

ControlSnapshot ReadControl(const ClockState* clock) {
  for (;;) {
    const uint32_t before = clock->seq.load(std::memory_order_acquire);
    if ((before & 1u) != 0u) continue;

    ControlSnapshot out{
        clock->mode.load(std::memory_order_relaxed),
        clock->epoch.load(std::memory_order_relaxed),
        clock->base_frame.load(std::memory_order_relaxed),
        clock->base_phase_num.load(std::memory_order_relaxed),
        clock->base_phase_den.load(std::memory_order_relaxed),
        clock->origin_monotonic_ns.load(std::memory_order_relaxed),
        clock->origin_sample.load(std::memory_order_relaxed),
        clock->latency_samples.load(std::memory_order_relaxed),
        clock->sample_rate.load(std::memory_order_relaxed),
        clock->fps_num.load(std::memory_order_relaxed),
        clock->fps_den.load(std::memory_order_relaxed),
    };

    // The acquire fence prevents any body load above from being reordered
    // after the sequence recheck. The recheck itself can then be relaxed.
    // This is the reader half of the seqlock contract on weak memory models.
    std::atomic_thread_fence(std::memory_order_acquire);
    const uint32_t after = clock->seq.load(std::memory_order_relaxed);
    if (before == after && (after & 1u) == 0u) return out;
  }
}

__int128 Abs128(__int128 value) { return value < 0 ? -value : value; }

__int128 Gcd128(__int128 a, __int128 b) {
  a = Abs128(a);
  b = Abs128(b);
  while (b != 0) {
    const __int128 next = a % b;
    a = b;
    b = next;
  }
  return a == 0 ? 1 : a;
}

}  // namespace

extern "C" {

struct R3ClockSnapshot {
  int64_t frame;
  int64_t phase_num;
  int64_t phase_den;
  uint64_t epoch;
  int32_t mode;
  int32_t padding;
};

namespace {

void NormalizeTime(__int128 numerator, __int128 denominator,
                   R3ClockSnapshot* out) {
  if (denominator <= 0) {
    out->frame = 0;
    out->phase_num = 0;
    out->phase_den = 1;
    return;
  }

  __int128 frame = numerator / denominator;
  __int128 remainder = numerator % denominator;
  if (remainder < 0) {
    remainder += denominator;
    frame -= 1;
  }

  const __int128 gcd = Gcd128(remainder, denominator);
  remainder /= gcd;
  denominator /= gcd;

  out->frame = static_cast<int64_t>(frame);
  out->phase_num = static_cast<int64_t>(remainder);
  out->phase_den = static_cast<int64_t>(denominator);
}

void EvaluateDelta(const ControlSnapshot& control, __int128 delta_num,
                   __int128 delta_den, R3ClockSnapshot* out) {
  const int64_t base_den =
      control.base_phase_den > 0 ? control.base_phase_den : 1;
  const __int128 base_num =
      static_cast<__int128>(control.base_frame) * base_den +
      control.base_phase_num;
  const __int128 numerator =
      base_num * delta_den + delta_num * base_den;
  const __int128 denominator = static_cast<__int128>(base_den) * delta_den;
  NormalizeTime(numerator, denominator, out);
}

}  // namespace

void* r3_clock_create(int64_t fps_num, int64_t fps_den) {
  if (fps_num <= 0 || fps_den <= 0) return nullptr;
  auto* clock = new ClockState();
  clock->fps_num.store(fps_num, std::memory_order_relaxed);
  clock->fps_den.store(fps_den, std::memory_order_relaxed);
  clock->origin_monotonic_ns.store(MonotonicNs(), std::memory_order_relaxed);
  return clock;
}

void r3_clock_destroy(void* handle) {
  delete static_cast<ClockState*>(handle);
}

void r3_clock_set_rate(void* handle, int64_t fps_num, int64_t fps_den) {
  auto* clock = static_cast<ClockState*>(handle);
  if (clock == nullptr || fps_num <= 0 || fps_den <= 0) return;
  const ControlWriteGuard write(clock);
  clock->fps_num.store(fps_num, std::memory_order_relaxed);
  clock->fps_den.store(fps_den, std::memory_order_relaxed);
}

void r3_clock_seek_monotonic(void* handle, int64_t frame,
                             int64_t phase_num, int64_t phase_den) {
  auto* clock = static_cast<ClockState*>(handle);
  if (clock == nullptr || phase_den <= 0) return;
  const ControlWriteGuard write(clock);
  clock->epoch.store(clock->epoch.load(std::memory_order_relaxed) + 1,
                     std::memory_order_relaxed);
  clock->mode.store(kMonotonic, std::memory_order_relaxed);
  clock->base_frame.store(frame, std::memory_order_relaxed);
  clock->base_phase_num.store(phase_num, std::memory_order_relaxed);
  clock->base_phase_den.store(phase_den, std::memory_order_relaxed);
  clock->origin_monotonic_ns.store(MonotonicNs(), std::memory_order_relaxed);
}

void r3_clock_seek_scrub(void* handle, int64_t frame, int64_t phase_num,
                         int64_t phase_den) {
  auto* clock = static_cast<ClockState*>(handle);
  if (clock == nullptr || phase_den <= 0) return;
  const ControlWriteGuard write(clock);
  clock->epoch.store(clock->epoch.load(std::memory_order_relaxed) + 1,
                     std::memory_order_relaxed);
  clock->mode.store(kScrub, std::memory_order_relaxed);
  clock->base_frame.store(frame, std::memory_order_relaxed);
  clock->base_phase_num.store(phase_num, std::memory_order_relaxed);
  clock->base_phase_den.store(phase_den, std::memory_order_relaxed);
}

void r3_clock_seek_audio(void* handle, int64_t frame, int64_t phase_num,
                         int64_t phase_den, int64_t origin_sample,
                         int64_t sample_rate, int64_t latency_samples) {
  auto* clock = static_cast<ClockState*>(handle);
  if (clock == nullptr || phase_den <= 0 || sample_rate <= 0) return;
  const ControlWriteGuard write(clock);
  clock->epoch.store(clock->epoch.load(std::memory_order_relaxed) + 1,
                     std::memory_order_relaxed);
  clock->mode.store(kAudio, std::memory_order_relaxed);
  clock->base_frame.store(frame, std::memory_order_relaxed);
  clock->base_phase_num.store(phase_num, std::memory_order_relaxed);
  clock->base_phase_den.store(phase_den, std::memory_order_relaxed);
  clock->origin_sample.store(origin_sample, std::memory_order_relaxed);
  clock->sample_rate.store(sample_rate, std::memory_order_relaxed);
  clock->latency_samples.store(latency_samples, std::memory_order_relaxed);
}

void r3_clock_set_latency_samples(void* handle, int64_t latency_samples) {
  auto* clock = static_cast<ClockState*>(handle);
  if (clock == nullptr) return;
  const ControlWriteGuard write(clock);
  clock->latency_samples.store(latency_samples, std::memory_order_relaxed);
}

void r3_clock_set_played_samples(void* handle, int64_t played_samples) {
  auto* clock = static_cast<ClockState*>(handle);
  if (clock == nullptr) return;
  clock->played_samples.store(played_samples, std::memory_order_release);
}

void r3_clock_add_played_samples(void* handle, int64_t samples) {
  auto* clock = static_cast<ClockState*>(handle);
  if (clock == nullptr) return;
  clock->played_samples.fetch_add(samples, std::memory_order_acq_rel);
}

const R3ClockSnapshot* r3_clock_read(void* handle) {
  static thread_local R3ClockSnapshot out;
  out = R3ClockSnapshot{0, 0, 1, 0, kMonotonic, 0};

  const auto* clock = static_cast<const ClockState*>(handle);
  if (clock == nullptr) return &out;

  const ControlSnapshot control = ReadControl(clock);
  out.epoch = control.epoch;
  out.mode = control.mode;

  if (control.mode == kScrub) {
    const int64_t base_den =
        control.base_phase_den > 0 ? control.base_phase_den : 1;
    NormalizeTime(static_cast<__int128>(control.base_frame) * base_den +
                      control.base_phase_num,
                  base_den, &out);
    return &out;
  }

  if (control.mode == kAudio) {
    const int64_t played = clock->played_samples.load(std::memory_order_acquire);
    const int64_t audible =
        played - control.origin_sample - control.latency_samples;
    const __int128 raw_num =
        static_cast<__int128>(audible) * control.fps_num;
    const __int128 raw_den =
        static_cast<__int128>(control.sample_rate) * control.fps_den;
    const __int128 gcd = Gcd128(raw_num, raw_den);
    EvaluateDelta(control, raw_num / gcd, raw_den / gcd, &out);
    return &out;
  }

  int64_t elapsed_ns = MonotonicNs() - control.origin_monotonic_ns;
  if (elapsed_ns < 0) elapsed_ns = 0;
  const __int128 raw_num =
      static_cast<__int128>(elapsed_ns) * control.fps_num;
  const __int128 raw_den =
      static_cast<__int128>(1000000000LL) * control.fps_den;
  const __int128 gcd = Gcd128(raw_num, raw_den);
  EvaluateDelta(control, raw_num / gcd, raw_den / gcd, &out);
  return &out;
}

}  // extern "C"
