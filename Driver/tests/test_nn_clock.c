#include "../NoNoiseMic/nn_clock.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s\n", m); failures++; } }while(0)

int main(void) {
    // 1 GHz host clock, 48k sr, 512-frame period. One period = 512/48000 s = 10666.67us
    // = 10666666.67 host ticks.
    nn_clock c;
    nn_clock_init(&c, /*anchor*/1000, /*ticks/s*/1e9, /*sr*/48000.0, /*period*/512);
    uint64_t st = 0, ht = 0;
    double periodTicks = (512.0 / 48000.0) * 1e9; // ~10,666,666.67

    // Just after the first full period: sampleTime should be 0 then advance to 512.
    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 0.5), &st, &ht);
    CHECK(st == 0, "before the first boundary, sampleTime stays 0");

    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 1.5), &st, &ht);
    CHECK(st == 512, "after one period, sampleTime advances by exactly one period");

    // CONTINUITY CONTRACT: even when host time is several periods ahead, a single call
    // advances AT MOST ONE period (the HAL requires a continuous timeline; multi-period
    // jumps caused IO-overload storms in the field — see nn_clock.h).
    uint32_t adv = nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 3.2), &st, &ht);
    CHECK(st == 512 * 2, "one call advances at most one period even when several are due");
    CHECK(adv == 1, "advance flag reports the single boundary crossing");

    // Repeated calls catch up one period at a time.
    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 3.2), &st, &ht);
    CHECK(st == 512 * 3, "next call advances the next period (incremental catch-up)");
    adv = nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 3.2), &st, &ht);
    CHECK(st == 512 * 3 && adv == 0, "no advance once caught up to the latest boundary");

    // Monotonic: never goes backwards even if asked for an earlier time.
    uint64_t prev = st;
    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 1.0), &st, &ht);
    CHECK(st >= prev, "zero-timestamp must be monotonic (never regress)");

    // RESYNC (the one-shot catch-up used by StartIO): lands on the latest boundary at/below
    // now in O(1), so a late-joining device starts on the shared sample axis. 2 hours @ 48k.
    nn_clock c2;
    nn_clock_init(&c2, /*anchor*/0, /*ticks/s*/1e9, /*sr*/48000.0, /*period*/512);
    uint64_t st2 = 0, ht2 = 0;
    double twoHoursTicks = 2.0 * 3600.0 * 1e9;
    nn_clock_resync(&c2, (uint64_t)twoHoursTicks);
    uint64_t expectedPeriods = (uint64_t)(twoHoursTicks / ((512.0 / 48000.0) * 1e9));
    nn_clock_get_zero_timestamp(&c2, (uint64_t)twoHoursTicks, &st2, &ht2);
    CHECK(st2 == expectedPeriods * 512, "resync lands on the exact boundary at/below now");

    // Resync never rewinds an already-running clock.
    nn_clock_resync(&c2, (uint64_t)(twoHoursTicks * 0.5));
    nn_clock_get_zero_timestamp(&c2, (uint64_t)twoHoursTicks, &st2, &ht2);
    CHECK(st2 >= expectedPeriods * 512, "resync is monotonic (never rewinds)");

    // After resync, normal calls continue one period at a time.
    adv = nn_clock_get_zero_timestamp(&c2, (uint64_t)(twoHoursTicks + periodTicks * 5.0), &st2, &ht2);
    CHECK(st2 == (expectedPeriods + 1) * 512 && adv == 1,
          "post-resync advance is single-period (continuous timeline)");

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("nn_clock: all tests passed\n");
    return 0;
}
