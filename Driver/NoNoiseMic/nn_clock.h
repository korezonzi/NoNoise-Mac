// nn_clock.h — CoreAudio-free zero-timestamp math for a fixed-period virtual device.
//
// LOCK-FREE by design: `nn_clock_get_zero_timestamp` is called from coreaudiod's REALTIME
// IO threads (one per IO context, every cycle). It must never take a mutex — a blocked RT
// thread misses its deadline, the HALC IOWorkLoop logs "out of order"/"overload", and with
// enough contention coreaudiod's IO bring-up wedges system-wide (observed in the field).
//
// TIMELINE CONTINUITY (also observed in the field): the HAL schedules IO cycles off the
// zero-timestamp sequence and expects it to advance CONTINUOUSLY — one period at a time,
// like a real device's clock (BlackHole behaves this way). An implementation that "catches
// up" by jumping many periods in a single call presents a discontinuous timeline; the HAL
// responds with a storm of IO overload reports that can wedge coreaudiod's IO bring-up
// queue system-wide. Therefore:
//   - `nn_clock_resync` performs the ONLY catch-up jump, at the moment a device's IO
//     starts (so a late-joining device lands on the shared ring's sample axis), and
//   - `nn_clock_get_zero_timestamp` then advances AT MOST ONE period per call.
//
// Concurrency contract:
//   - `sampleTime` is a C11 atomic advanced with a monotonic CAS (readers race safely).
//   - `anchorHostTime` is atomic; the remaining fields are constants re-written only by
//     `nn_clock_init`, which the driver calls ONLY while no IO is running on any device
//     (StartIO with gIOCount==0), and always with the same values.
#ifndef NN_CLOCK_H
#define NN_CLOCK_H
#include <stdint.h>
#include <stdatomic.h>

typedef struct {
    _Atomic uint64_t anchorHostTime; // host ticks at the moment the shared epoch started
    double   hostTicksPerSecond;     // mach timebase: ticks per second
    double   sampleRate;             // e.g. 48000.0
    uint32_t periodFrames;           // zero-timestamp period in frames
    _Atomic uint64_t sampleTime;     // running zero-timestamp sample position (monotonic)
} nn_clock;

void nn_clock_init(nn_clock *c, uint64_t anchorHostTime, double hostTicksPerSecond,
                   double sampleRate, uint32_t periodFrames);

// One-shot catch-up: place the clock at the latest period boundary at/below `currentHostTime`.
// Call ONLY from StartIO when this device's IO transitions to running (non-realtime context is
// fine there). This is what keeps a late-joining device on the same absolute sample axis as
// devices that have been running since the shared anchor was set.
void nn_clock_resync(nn_clock *c, uint64_t currentHostTime);

// Advance AT MOST ONE period if the next boundary has been reached, then write the current
// zero-timestamp pair. Returns 1 if a period boundary was crossed, else 0.
// Realtime-safe: lock-free, bounded CAS, no syscalls.
uint32_t nn_clock_get_zero_timestamp(nn_clock *c, uint64_t currentHostTime,
                                     uint64_t *outSampleTime, uint64_t *outHostTime);
#endif
