#include "nn_clock.h"

static double period_ticks(const nn_clock *c) {
    return ((double)c->periodFrames / c->sampleRate) * c->hostTicksPerSecond;
}

void nn_clock_init(nn_clock *c, uint64_t anchorHostTime, double hostTicksPerSecond,
                   double sampleRate, uint32_t periodFrames) {
    // Only called while no IO runs on any device (StartIO with gIOCount==0), so the plain
    // fields cannot race a live reader; the atomics publish the fresh epoch.
    c->hostTicksPerSecond = hostTicksPerSecond;
    c->sampleRate = sampleRate;
    c->periodFrames = periodFrames;
    atomic_store_explicit(&c->sampleTime, 0, memory_order_relaxed);
    atomic_store_explicit(&c->anchorHostTime, anchorHostTime, memory_order_release);
}

void nn_clock_resync(nn_clock *c, uint64_t currentHostTime) {
    const uint64_t anchor = atomic_load_explicit(&c->anchorHostTime, memory_order_acquire);
    const double pt = period_ticks(c);
    uint64_t sample = 0;
    if (currentHostTime > anchor && pt > 0.0) {
        double elapsed = (double)(currentHostTime - anchor);
        uint64_t periodIndex = (uint64_t)(elapsed / pt);   // floor → boundary at/below now
        sample = periodIndex * (uint64_t)c->periodFrames;
    }
    // Monotonic max: never move a clock backwards (a second client starting IO on a device
    // that is already running must not rewind the timeline it is publishing).
    uint64_t prev = atomic_load_explicit(&c->sampleTime, memory_order_relaxed);
    while (sample > prev &&
           !atomic_compare_exchange_weak_explicit(&c->sampleTime, &prev, sample,
                                                  memory_order_acq_rel, memory_order_relaxed)) {
    }
}

// Advance AT MOST ONE period per call (see header: timeline continuity is a HAL requirement —
// multi-period jumps here produced IO-overload storms that wedged coreaudiod system-wide).
uint32_t nn_clock_get_zero_timestamp(nn_clock *c, uint64_t currentHostTime,
                                     uint64_t *outSampleTime, uint64_t *outHostTime) {
    const uint64_t anchor = atomic_load_explicit(&c->anchorHostTime, memory_order_acquire);
    const double pt = period_ticks(c);

    uint64_t cur = atomic_load_explicit(&c->sampleTime, memory_order_relaxed);
    uint32_t advanced = 0;
    if (pt > 0.0) {
        // Host time of the NEXT boundary after the currently published one.
        const double curPeriods = (double)cur / (double)c->periodFrames;
        const uint64_t nextHost = anchor + (uint64_t)((curPeriods + 1.0) * pt);
        if (currentHostTime >= nextHost) {
            const uint64_t next = cur + c->periodFrames;
            // Single-step CAS: if another RT reader already advanced it, accept their value —
            // both observe a continuous, monotonic sequence either way.
            if (atomic_compare_exchange_strong_explicit(&c->sampleTime, &cur, next,
                                                        memory_order_acq_rel,
                                                        memory_order_relaxed)) {
                cur = next;
                advanced = 1;
            }
            // On CAS failure `cur` was reloaded with the newer value.
        }
    }

    double hostOffset = ((double)cur / c->sampleRate) * c->hostTicksPerSecond;
    *outSampleTime = cur;
    *outHostTime = anchor + (uint64_t)hostOffset;
    return advanced;
}
