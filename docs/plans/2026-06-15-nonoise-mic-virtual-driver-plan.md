# NoNoise Mic — Virtual Microphone Driver (Tier 3, Spec A) — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a virtual microphone named **"NoNoise Mic"** (a userspace AudioServerPlugIn) that the NoNoise Mac app feeds with DeepFilterNet-cleaned audio, so Slack/Zoom/Meet/OBS can select it directly — no BlackHole required, no system-default juggling.

**Architecture:** A C AudioServerPlugIn (`NoNoiseMic.driver`, based on Apple's permissively-licensed sample) publishes a visible input-only device "NoNoise Mic" (48 kHz, 2ch) plus a hidden output-only device "NoNoise Mic Engine". A custom `sourceMode` ('srcm') device property selects where the visible input's samples come from: an internal **loopback** circular buffer the engine device feeds (Phase A1), or a **shared-memory ring** the app fills over XPC (Phase A2). The existing `AudioModel` engine routes its output to the hidden engine device (A1) exactly as it does to BlackHole today. The riskiest pure math (circular-buffer wraparound + zero-timestamp clock) is factored into CoreAudio-free C and host-unit-tested in CI.

**Tech Stack:** C11 (driver + pure helpers, `clang -bundle`), CoreAudio `AudioServerPlugIn` API, Swift 5.9 / SwiftUI (app), XCTest (Swift unit tests), a tiny C test harness (host ring/timestamp tests), shell (`build/install/uninstall-driver.sh`), GitHub Actions CI.

**Execution location:** All edits and commits go inside `/Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src/`.

**Source of truth:** the design spec `docs/plans/2026-06-15-nonoise-mic-virtual-driver-design.md` (r2, both reviewers APPROVED). Read it before starting.

---

## Shared contract constants (single source of truth — a mismatch fails SILENTLY)

These appear in BOTH the driver (C) and the app (Swift). Define once per language; keep identical.

| Constant | Value |
|---|---|
| Plug-in bundle id | `com.ivalsaraj.NoNoiseMic` |
| Driver bundle dir | `NoNoiseMic.driver` |
| Visible device name | `NoNoise Mic` |
| Visible device UID | `NoNoiseMic:visible:48k2ch` |
| Hidden engine device name | `NoNoise Mic Engine` |
| Hidden engine device UID | `NoNoiseMic:engine:48k2ch` |
| `sourceMode` property selector | `'srcm'` (FourCharCode `0x7372636D`), scope `kAudioObjectPropertyScopeGlobal`, element `0` |
| `sourceMode` values | `0` = loopback (A1 default), `1` = xpc (A2) |
| Sample rate | `48000.0` |
| Channels | `2` (stereo) |
| Format | Float32, packed, non-interleaved-per-stream per CoreAudio convention |
| HAL install dir | `/Library/Audio/Plug-Ins/HAL` |

---

# PHASE A1 — loopback + auto-route (ships first)

## Task 1: Vendor the Apple AudioServerPlugIn sample as the driver baseline

**Files:**
- Create: `Driver/NoNoiseMic/` (new top-level dir)
- Create: `Driver/NoNoiseMic/NoNoiseMic.c` (baseline = Apple sample, renamed)
- Create: `Driver/NoNoiseMic/Info.plist`
- Create: `Driver/README.md` (provenance + license note)

**Step 1: Create the directory and provenance note**

`Driver/README.md`:
```markdown
# NoNoise Mic — AudioServerPlugIn driver

`NoNoiseMic.driver` is a userspace CoreAudio HAL plug-in. Its baseline is Apple's
"Creating an Audio Server Driver Plug-in" sample (SimpleAudio/NullAudio), used under the
**Apple Sample Code License** (notice retained at the top of `NoNoiseMic.c`). It is NOT
derived from BlackHole (GPL-3.0); BlackHole was reference reading only.

Build:   ../build-driver.sh
Install: sudo ../install-driver.sh     (copies to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod)
```

**Step 2: Obtain the Apple sample and place it as `NoNoiseMic.c`**

Download Apple's "Creating an Audio Server Driver Plug-in" sample (developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in). Copy its single `.c` implementation to `Driver/NoNoiseMic/NoNoiseMic.c` and its `Info.plist` to `Driver/NoNoiseMic/Info.plist`. Keep the Apple Sample Code License header verbatim at the top of `NoNoiseMic.c`.

> Fallback if the sample is unavailable: author a minimal AudioServerPlugIn following `CoreAudio/AudioServerPlugIn.h` (the 22-method `AudioServerPlugInDriverInterface`), implementing exactly one input device + the standard property/IO methods. This is a larger sub-effort; prefer vendoring the sample.

**Step 3: Verify the baseline is the unmodified sample (no behavior changes yet)**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
ls Driver/NoNoiseMic/NoNoiseMic.c Driver/NoNoiseMic/Info.plist
head -20 Driver/NoNoiseMic/NoNoiseMic.c   # expect Apple Sample Code License header
```

**Step 4: Commit (baseline only, before any customization)**

```bash
git add Driver/NoNoiseMic/NoNoiseMic.c Driver/NoNoiseMic/Info.plist Driver/README.md
git commit -m "chore(driver): vendor Apple AudioServerPlugIn sample as NoNoise Mic baseline"
```

---

## Task 2: Pure C circular-buffer (wraparound index math) — TDD, host-tested

A CoreAudio-free fixed circular buffer indexed by absolute sample time — the exact model a HAL loopback uses (write at output `mSampleTime`, read at input `mSampleTime`). No FIFO head/tail; the shared clock keeps reads trailing writes.

**Files:**
- Create: `Driver/NoNoiseMic/nn_ring.h`
- Create: `Driver/NoNoiseMic/nn_ring.c`
- Create: `Driver/tests/test_nn_ring.c`
- Create: `Driver/tests/run-tests.sh`

**Step 1: Write `nn_ring.h`**

```c
// nn_ring.h — CoreAudio-free fixed circular buffer indexed by absolute sample time.
// Single-writer (output IO cycle) / single-reader (input IO cycle); the shared HAL
// clock keeps the reader trailing the writer. No locks, no allocation, no syscalls.
#ifndef NN_RING_H
#define NN_RING_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    float   *storage;        // caller-owned: capacityFrames * channels floats
    uint32_t capacityFrames; // MUST be a power of two
    uint32_t channels;
} nn_ring;

// Initialize. capacityFrames MUST be a power of two. Returns 0 on success, -1 on bad args.
int  nn_ring_init(nn_ring *r, float *storage, uint32_t capacityFrames, uint32_t channels);

// Zero the storage.
void nn_ring_clear(nn_ring *r);

// Write `frames` interleaved frames starting at absolute sample time `sampleTime`,
// wrapping modulo capacity. `src` length = frames * channels.
void nn_ring_write_at(nn_ring *r, uint64_t sampleTime, const float *src, uint32_t frames);

// Read `frames` interleaved frames starting at absolute sample time `sampleTime`,
// wrapping modulo capacity, into `dst` (length = frames * channels).
void nn_ring_read_at(nn_ring *r, uint64_t sampleTime, float *dst, uint32_t frames);

#endif
```

**Step 2: Write the failing test `Driver/tests/test_nn_ring.c`**

```c
#include "../NoNoiseMic/nn_ring.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, msg) do { if(!(cond)){ printf("FAIL: %s\n", msg); failures++; } } while(0)

static void test_write_read_roundtrip(void) {
    float store[8 * 2]; nn_ring r;
    assert(nn_ring_init(&r, store, 8, 2) == 0);
    nn_ring_clear(&r);
    float in[4 * 2], out[4 * 2];
    for (int i = 0; i < 8; i++) in[i] = (float)i;
    nn_ring_write_at(&r, 0, in, 4);
    nn_ring_read_at(&r, 0, out, 4);
    CHECK(memcmp(in, out, sizeof in) == 0, "roundtrip at t=0 must match");
}

static void test_wraparound(void) {
    float store[8 * 1]; nn_ring r;
    nn_ring_init(&r, store, 8, 1);
    nn_ring_clear(&r);
    float in[6], out[6];
    for (int i = 0; i < 6; i++) in[i] = (float)(i + 1);
    nn_ring_write_at(&r, 6, in, 6);   // writes indices 6,7,0,1,2,3 (wraps)
    nn_ring_read_at(&r, 6, out, 6);
    CHECK(memcmp(in, out, sizeof in) == 0, "write/read across the wrap boundary must match");
}

static void test_init_rejects_non_pow2(void) {
    float store[10]; nn_ring r;
    CHECK(nn_ring_init(&r, store, 5, 1) == -1, "non-power-of-two capacity must be rejected");
    CHECK(nn_ring_init(&r, store, 0, 1) == -1, "zero capacity must be rejected");
}

int main(void) {
    test_write_read_roundtrip();
    test_wraparound();
    test_init_rejects_non_pow2();
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("nn_ring: all tests passed\n");
    return 0;
}
```

**Step 3: Write `Driver/tests/run-tests.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
clang -std=c11 -Wall -Wextra -O2 test_nn_ring.c ../NoNoiseMic/nn_ring.c -o /tmp/nn_ring_test
clang -std=c11 -Wall -Wextra -O2 test_nn_clock.c ../NoNoiseMic/nn_clock.c -o /tmp/nn_clock_test 2>/dev/null || true
/tmp/nn_ring_test
[ -x /tmp/nn_clock_test ] && /tmp/nn_clock_test || true
```
Make executable: `chmod +x Driver/tests/run-tests.sh`.

**Step 4: Run the test — verify it FAILS to compile/link (no `nn_ring.c` yet)**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
clang -std=c11 Driver/tests/test_nn_ring.c Driver/NoNoiseMic/nn_ring.c -o /tmp/nn_ring_test
```
Expected: FAIL (`nn_ring.c` missing / undefined symbols).

**Step 5: Implement `nn_ring.c`**

```c
#include "nn_ring.h"
#include <string.h>

static int is_pow2(uint32_t x) { return x != 0 && (x & (x - 1)) == 0; }

int nn_ring_init(nn_ring *r, float *storage, uint32_t capacityFrames, uint32_t channels) {
    if (!r || !storage || channels == 0 || !is_pow2(capacityFrames)) return -1;
    r->storage = storage;
    r->capacityFrames = capacityFrames;
    r->channels = channels;
    return 0;
}

void nn_ring_clear(nn_ring *r) {
    memset(r->storage, 0, (size_t)r->capacityFrames * r->channels * sizeof(float));
}

void nn_ring_write_at(nn_ring *r, uint64_t sampleTime, const float *src, uint32_t frames) {
    const uint32_t mask = r->capacityFrames - 1;
    const uint32_t ch = r->channels;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((sampleTime + i) & mask);
        memcpy(&r->storage[(size_t)slot * ch], &src[(size_t)i * ch], ch * sizeof(float));
    }
}

void nn_ring_read_at(nn_ring *r, uint64_t sampleTime, float *dst, uint32_t frames) {
    const uint32_t mask = r->capacityFrames - 1;
    const uint32_t ch = r->channels;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((sampleTime + i) & mask);
        memcpy(&dst[(size_t)i * ch], &r->storage[(size_t)slot * ch], ch * sizeof(float));
    }
}
```

**Step 6: Run the test — verify PASS**

```bash
clang -std=c11 -Wall -Wextra Driver/tests/test_nn_ring.c Driver/NoNoiseMic/nn_ring.c -o /tmp/nn_ring_test && /tmp/nn_ring_test
```
Expected: `nn_ring: all tests passed`.

**Step 7: Commit**

```bash
git add Driver/NoNoiseMic/nn_ring.h Driver/NoNoiseMic/nn_ring.c Driver/tests/test_nn_ring.c Driver/tests/run-tests.sh
git commit -m "feat(driver): add host-tested sample-time circular buffer (nn_ring)"
```

---

## Task 3: Pure C zero-timestamp clock — TDD, host-tested

The HAL calls `GetZeroTimeStamp` to anchor IO sample-time to host-time. Factor the math out so it's testable without CoreAudio: given an anchor host time, the host clock frequency, the sample rate, and the ring period, it returns a monotonically advancing (sampleTime, hostTime) pair that steps by exactly one ring period each cycle.

**Files:**
- Create: `Driver/NoNoiseMic/nn_clock.h`
- Create: `Driver/NoNoiseMic/nn_clock.c`
- Create: `Driver/tests/test_nn_clock.c`

**Step 1: `nn_clock.h`**

```c
// nn_clock.h — CoreAudio-free zero-timestamp math for a fixed-period virtual device.
#ifndef NN_CLOCK_H
#define NN_CLOCK_H
#include <stdint.h>

typedef struct {
    uint64_t anchorHostTime;     // host ticks at the moment IO started
    double   hostTicksPerSecond; // mach timebase: ticks per second
    double   sampleRate;         // e.g. 48000.0
    uint32_t periodFrames;       // ring period in frames (e.g. capacityFrames)
    uint64_t sampleTime;         // running zero-timestamp sample position
} nn_clock;

void nn_clock_init(nn_clock *c, uint64_t anchorHostTime, double hostTicksPerSecond,
                   double sampleRate, uint32_t periodFrames);

// Given the current host time, advance to the latest period boundary at or before it.
// Writes the zero-timestamp pair. Returns the number of periods advanced this call.
uint32_t nn_clock_get_zero_timestamp(nn_clock *c, uint64_t currentHostTime,
                                     uint64_t *outSampleTime, uint64_t *outHostTime);
#endif
```

**Step 2: Failing test `Driver/tests/test_nn_clock.c`**

```c
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

    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 3.2), &st, &ht);
    CHECK(st == 512 * 3, "monotonic advance to the latest boundary at/below now");

    // Monotonic: never goes backwards even if asked for an earlier time.
    uint64_t prev = st;
    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 1.0), &st, &ht);
    CHECK(st >= prev, "zero-timestamp must be monotonic (never regress)");

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("nn_clock: all tests passed\n");
    return 0;
}
```

**Step 3: Run — verify FAIL (no `nn_clock.c`).**

**Step 4: Implement `nn_clock.c`**

```c
#include "nn_clock.h"

void nn_clock_init(nn_clock *c, uint64_t anchorHostTime, double hostTicksPerSecond,
                   double sampleRate, uint32_t periodFrames) {
    c->anchorHostTime = anchorHostTime;
    c->hostTicksPerSecond = hostTicksPerSecond;
    c->sampleRate = sampleRate;
    c->periodFrames = periodFrames;
    c->sampleTime = 0;
}

uint32_t nn_clock_get_zero_timestamp(nn_clock *c, uint64_t currentHostTime,
                                     uint64_t *outSampleTime, uint64_t *outHostTime) {
    double periodTicks = ((double)c->periodFrames / c->sampleRate) * c->hostTicksPerSecond;
    uint32_t advanced = 0;
    // Advance whole periods while the next boundary's host time is <= now. Monotonic.
    for (;;) {
        uint64_t nextSample = c->sampleTime + c->periodFrames;
        double nextHostOffset = ((double)nextSample / c->sampleRate) * c->hostTicksPerSecond;
        uint64_t nextHost = c->anchorHostTime + (uint64_t)nextHostOffset;
        if (nextHost <= currentHostTime) { c->sampleTime = nextSample; advanced++; }
        else break;
    }
    double curHostOffset = ((double)c->sampleTime / c->sampleRate) * c->hostTicksPerSecond;
    *outSampleTime = c->sampleTime;
    *outHostTime = c->anchorHostTime + (uint64_t)curHostOffset;
    (void)periodTicks;
    return advanced;
}
```

**Step 5: Run — verify PASS** (`clang ... test_nn_clock.c nn_clock.c`). Then `Driver/tests/run-tests.sh` runs both.

**Step 6: Commit**

```bash
git add Driver/NoNoiseMic/nn_clock.h Driver/NoNoiseMic/nn_clock.c Driver/tests/test_nn_clock.c Driver/tests/run-tests.sh
git commit -m "feat(driver): add host-tested zero-timestamp clock (nn_clock)"
```

---

## Task 4: Customize the driver — topology, names/UIDs, sourceMode, IO via nn_ring

Apply precise deltas to the vendored `NoNoiseMic.c` + `Info.plist`. Reference the design spec's "The driver" section.

**Files:**
- Modify: `Driver/NoNoiseMic/NoNoiseMic.c`
- Modify: `Driver/NoNoiseMic/Info.plist`

**Step 1: Names, UIDs, format constants** — at the top of `NoNoiseMic.c`, set the device/box/stream constants to the shared contract values: visible device name `NoNoise Mic`, UID `NoNoiseMic:visible:48k2ch`; sample rate `48000`, channels `2`, format Float32. Bundle id `com.ivalsaraj.NoNoiseMic`.

**Step 2: Add the hidden engine device (Device 2)** — duplicate the sample's single-device object model into a second `AudioObjectID` "NoNoise Mic Engine" (UID `NoNoiseMic:engine:48k2ch`): output-only, `kAudioDevicePropertyIsHidden = 1`. Both devices share ONE `nn_ring` instance (file-scope static) and ONE `nn_clock` anchor created on the first IO start.

**Step 3: Bar the engine device from default selection** — in the engine device's property handlers, return `0` for `kAudioDevicePropertyDeviceCanBeDefaultDevice` and `kAudioDevicePropertyDeviceCanBeDefaultSystemDevice` (output scope). The visible device returns `1` (input-eligible).

**Step 4: Add the `sourceMode` custom property** — handle selector `'srcm'` (FourCharCode `0x73726D63`… use the exact code `'srcm'`), scope global, element 0:
- `HasProperty` / `IsPropertySettable` → true.
- `GetPropertyDataSize` → `sizeof(UInt32)`.
- `GetPropertyData` → current mode (`0` loopback default, `1` xpc).
- `SetPropertyData` → store the new mode (file-scope `static _Atomic uint32_t gSourceMode = 0;`), notify listeners.
(A2 reads this; A1 only needs the default `0`.)

**Step 5: Wire IO to `nn_ring`** — in `DoIOOperation`:
- Engine device, `kAudioServerPlugInIOOperationWriteMix` (output): `nn_ring_write_at(&gRing, ioCycleInfo->mOutputTime.mSampleTime, ioMainBuffer, frames)`.
- Visible device, `kAudioServerPlugInIOOperationReadInput` (input): if `gSourceMode == 0` → `nn_ring_read_at(&gRing, ioCycleInfo->mInputTime.mSampleTime, ioMainBuffer, frames)`. (A2 adds the `gSourceMode == 1` branch in Phase A2.)
- Use `nn_clock_get_zero_timestamp` in `GetZeroTimeStamp` for both devices off the shared anchor (cast mach `AudioGetCurrentHostTime()` + `AudioGetHostClockFrequency()` into `nn_clock`). Allocate `gRing` storage as a static `float[CAP*2]` with `CAP` a power of two ≥ 1 second (e.g. 65536).

**Step 6: Info.plist — exact CFPlugIn keys** (`Driver/NoNoiseMic/Info.plist`):
```xml
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleExecutable</key><string>NoNoiseMic</string>
<key>CFBundleIdentifier</key><string>com.ivalsaraj.NoNoiseMic</string>
<key>CFPlugInFactories</key>
<dict>
  <key>YOUR-FACTORY-UUID</key><string>NoNoiseMic_Create</string>
</dict>
<key>CFPlugInTypes</key>
<dict>
  <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>   <!-- kAudioServerPlugInTypeUUID -->
  <array><string>YOUR-FACTORY-UUID</string></array>
</dict>
```
(`NoNoiseMic_Create` is the exported factory symbol — rename the sample's factory accordingly. Generate a fresh factory UUID with `uuidgen`.)

**Step 7: Build sanity (compile only, no install)**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
clang -c -std=c11 -Wall Driver/NoNoiseMic/NoNoiseMic.c -o /tmp/NoNoiseMic.o && echo "compiles"
```
Expected: compiles (warnings ok; errors not).

**Step 8: Commit**

```bash
git add Driver/NoNoiseMic/NoNoiseMic.c Driver/NoNoiseMic/Info.plist
git commit -m "feat(driver): NoNoise Mic topology, sourceMode property, loopback IO via nn_ring"
```

---

## Task 5: Build / install / uninstall scripts (with verification)

**Files:**
- Create: `build-driver.sh`, `install-driver.sh`, `uninstall-driver.sh`

**Step 1: `build-driver.sh`** (compile the bundle, sign AFTER full assembly, print signature)

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DRIVER="NoNoiseMic.driver"
SRC="Driver/NoNoiseMic"
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
cp "$SRC/Info.plist" "$DRIVER/Contents/Info.plist"
clang -bundle -std=c11 -O2 -arch arm64 \
  -framework CoreAudio -framework CoreFoundation -framework AudioToolbox \
  "$SRC/NoNoiseMic.c" "$SRC/nn_ring.c" "$SRC/nn_clock.c" \
  -o "$DRIVER/Contents/MacOS/NoNoiseMic"
# Sign AFTER the bundle is fully assembled (post-sign edits invalidate the signature → silent non-load)
codesign --force --sign - "$DRIVER"
codesign -dv --verbose=4 "$DRIVER" 2>&1 | sed -n '1,6p'
echo "Built $DRIVER"
```

**Step 2: `install-driver.sh`** (copy, restart coreaudiod, VERIFY the device appeared)

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DRIVER="NoNoiseMic.driver"
DEST="/Library/Audio/Plug-Ins/HAL"
[ -d "$DRIVER" ] || { echo "Build first: ./build-driver.sh"; exit 1; }
echo "Installing to $DEST (requires admin; ALL audio will briefly drop on coreaudiod restart)…"
sudo rm -rf "$DEST/$DRIVER"
sudo cp -R "$DRIVER" "$DEST/"
sudo killall coreaudiod 2>/dev/null || true
sleep 3
# Verify: the device must now exist. system_profiler is the simplest user-space probe.
if system_profiler SPAudioDataType 2>/dev/null | grep -q "NoNoise Mic"; then
  echo "✅ NoNoise Mic installed and visible."
else
  echo "❌ NoNoise Mic did NOT appear. Check Console.app for coreaudiod plug-in errors"
  echo "   (common causes: bad CFPlugInFactories/CFPlugInTypes keys, invalid signature)."
  exit 1
fi
```

**Step 3: `uninstall-driver.sh`**

```bash
#!/bin/bash
set -euo pipefail
DEST="/Library/Audio/Plug-Ins/HAL/NoNoiseMic.driver"
sudo rm -rf "$DEST"
sudo killall coreaudiod 2>/dev/null || true
echo "Removed NoNoise Mic. (Audio dropped briefly to restart coreaudiod.)"
```

**Step 4: chmod + build smoke**

```bash
chmod +x build-driver.sh install-driver.sh uninstall-driver.sh
./build-driver.sh   # expect "Built NoNoiseMic.driver" + a signature dump
```
Expected: bundle builds and ad-hoc signs.

**Step 5: Commit**

```bash
git add build-driver.sh install-driver.sh uninstall-driver.sh
git commit -m "feat(driver): build/install/uninstall scripts with install-time verification"
```

> `NoNoiseMic.driver/` is a build artifact — add it to `.gitignore` in Task 10.

---

## Task 6: App-side pure logic + Swift unit tests — TDD

Pure, headless-testable functions for device selection/filtering. No CoreAudio calls inside them — they operate on a plain `[DeviceInfo]` so `swift test` runs in CI.

**Files:**
- Create: `Sources/Core/AudioProcessing/VirtualMicRouting.swift`
- Modify: `Tests/NoNoiseMacTests/` → create `VirtualMicRoutingTests.swift`

**Step 1: Write the failing test `Tests/NoNoiseMacTests/VirtualMicRoutingTests.swift`**

```swift
import XCTest
@testable import Core

final class VirtualMicRoutingTests: XCTestCase {
    private func dev(_ name: String, hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        .init(uid: name, name: name, isHidden: hidden, hasOutput: true)
    }

    func testAutoRoutePrefersEngineDevice() {
        let list = [dev("BlackHole 2ch"), dev(VirtualMicRouting.engineDeviceName, hidden: true), dev("MacBook Speakers")]
        let pick = VirtualMicRouting.preferredOutputUID(from: list)
        XCTAssertEqual(pick, VirtualMicRouting.engineDeviceName)
    }

    func testAutoRouteFallsBackToBlackHoleWhenNoEngine() {
        let list = [dev("BlackHole 2ch"), dev("MacBook Speakers")]
        XCTAssertEqual(VirtualMicRouting.preferredOutputUID(from: list), "BlackHole 2ch")
    }

    func testAutoRouteNeverPicksPhysicalOutput() {
        // No virtual sink present → must NOT auto-route to a physical device.
        let list = [dev("MacBook Speakers"), dev("USB Headphones")]
        XCTAssertNil(VirtualMicRouting.preferredOutputUID(from: list))
    }

    func testHiddenEngineFilteredFromOutputPicker() {
        let list = [dev("BlackHole 2ch"), dev(VirtualMicRouting.engineDeviceName, hidden: true)]
        let visible = VirtualMicRouting.visibleOutputs(from: list).map(\.name)
        XCTAssertFalse(visible.contains(VirtualMicRouting.engineDeviceName))
        XCTAssertTrue(visible.contains("BlackHole 2ch"))
    }

    func testVirtualMicFilteredFromInputList() {
        let inputs = ["Built-in Microphone", VirtualMicRouting.visibleDeviceName, "USB Mic"]
        let filtered = VirtualMicRouting.filterInputs(inputs)
        XCTAssertFalse(filtered.contains(VirtualMicRouting.visibleDeviceName))
        XCTAssertEqual(filtered, ["Built-in Microphone", "USB Mic"])
    }
}
```

**Step 2: Run — verify FAIL** (`swift test --filter VirtualMicRoutingTests` → no such type).

**Step 3: Implement `Sources/Core/AudioProcessing/VirtualMicRouting.swift`**

```swift
import Foundation

/// Pure, headless-testable routing/filtering logic for the NoNoise Mic virtual driver.
/// Operates on plain values (no CoreAudio) so it runs under `swift test`.
public enum VirtualMicRouting {
    // Shared contract — keep identical to the driver's constants.
    public static let visibleDeviceName = "NoNoise Mic"
    public static let engineDeviceName  = "NoNoise Mic Engine"
    public static let visibleDeviceUID  = "NoNoiseMic:visible:48k2ch"
    public static let engineDeviceUID   = "NoNoiseMic:engine:48k2ch"

    /// Known virtual sinks we will auto-route to, in priority order. A physical
    /// output is NEVER a fallback (would play cleaned audio aloud, not feed a mic).
    private static let fallbackVirtualSinks = ["BlackHole"]

    public struct DeviceInfo: Equatable {
        public let uid: String
        public let name: String
        public let isHidden: Bool
        public let hasOutput: Bool
        public init(uid: String, name: String, isHidden: Bool, hasOutput: Bool) {
            self.uid = uid; self.name = name; self.isHidden = isHidden; self.hasOutput = hasOutput
        }
    }

    /// Output device the engine should render into: the hidden engine device if
    /// present, else a known virtual sink (BlackHole), else nil (do NOT route to
    /// a physical output — surface "install the driver" instead).
    public static func preferredOutputUID(from devices: [DeviceInfo]) -> String? {
        if let engine = devices.first(where: { $0.name == engineDeviceName }) { return engine.uid }
        if let bh = devices.first(where: { d in fallbackVirtualSinks.contains(where: { d.name.contains($0) }) }) {
            return bh.uid
        }
        return nil
    }

    /// Output devices to show in the app's own picker — hidden devices excluded.
    public static func visibleOutputs(from devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.filter { !$0.isHidden }
    }

    /// Remove the virtual mic from a list of input device names (prevents a
    /// feedback loop if the user could otherwise select it as the capture source).
    public static func filterInputs(_ names: [String]) -> [String] {
        names.filter { $0 != visibleDeviceName && $0 != engineDeviceName }
    }
}
```
(Note: in `preferredOutputUID`, BlackHole's UID would be its real device UID at runtime; the test passes `uid == name` for simplicity.)

**Step 4: Run — verify PASS**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test --filter VirtualMicRoutingTests
```
Expected: 5 tests pass.

**Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/VirtualMicRouting.swift Tests/NoNoiseMacTests/VirtualMicRoutingTests.swift
git commit -m "feat(core): add pure virtual-mic routing/filtering logic + tests"
```

---

## Task 7: Wire routing into `AudioModel`

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

**Step 1: Add `kAudioDevicePropertyIsHidden` to `fetchOutputDevices`** — after reading each device name, query its hidden flag and skip hidden devices (drops "NoNoise Mic Engine" from the picker). Build a `[VirtualMicRouting.DeviceInfo]` alongside `[DeviceStruct]`.

```swift
// inside the device loop, after obtaining `cf as String`:
var hidden: UInt32 = 0
var hiddenSize = UInt32(MemoryLayout<UInt32>.size)
var hiddenAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden,
                                            mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
if AudioObjectHasProperty(id, &hiddenAddr) {
    AudioObjectGetPropertyData(id, &hiddenAddr, 0, nil, &hiddenSize, &hidden)
}
if hidden == 0 {
    newDevs.append(DeviceStruct(id: id, name: cf as String))
}
allDevs.append(VirtualMicRouting.DeviceInfo(uid: (cf as String), name: (cf as String),
                                            isHidden: hidden != 0, hasOutput: true))
```

**Step 2: Resolve the hidden engine device by UID and auto-route to it** — add a helper using `kAudioHardwarePropertyTranslateUIDToDevice`, and prefer it in the default-output selection (replacing the current "default to BlackHole"):

```swift
private func deviceID(forUID uid: String) -> AudioObjectID {
    var translated = AudioObjectID(0)
    var cfUID = uid as CFString
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    withUnsafeMutablePointer(to: &cfUID) { uidPtr in
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &translated)
    }
    return translated
}
```
In `fetchOutputDevices`'s `DispatchQueue.main.async` block, set `driverInstalled` and prefer the engine device:
```swift
let engineID = self.deviceID(forUID: VirtualMicRouting.engineDeviceUID)
self.driverInstalled = engineID != 0
if engineID != 0 {
    self.selectedOutputDeviceID = engineID
} else if let bh = newDevs.first(where: { $0.name.contains("BlackHole") }) {
    self.selectedOutputDeviceID = bh.id
}
// else: leave unset — do NOT auto-route to a physical output.
```

**Step 3: Add `driverInstalled` published state**

```swift
@Published public var driverInstalled: Bool = false
```

**Step 4: Filter the virtual mic out of the input list** — in `fetchInputDevices`, after building `devs`, drop any whose `localizedName` is a NoNoise Mic device:
```swift
devs = devs.filter { VirtualMicRouting.filterInputs([$0.localizedName]).isEmpty == false }
```

**Step 5: Build + test**

```bash
swift build && swift test
```
Expected: clean build; all tests pass (existing 30 + 5 new).

**Step 6: Commit**

```bash
git add Sources/Core/AudioModel.swift
git commit -m "feat(core): auto-route engine device, filter hidden/virtual devices"
```

---

## Task 8: Minimal "driver installed" status row (UI)

**Files:**
- Modify: `Sources/App/ContentView.swift`

**Step 1: Add a status row** under the devices card (only when not installed, keep it minimal):

```swift
if !audioModel.driverInstalled {
    HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        VStack(alignment: .leading, spacing: 1) {
            Text("NoNoise Mic not installed").font(.caption).fontWeight(.medium)
            Text("Run ./install-driver.sh to add the virtual mic.")
                .font(.caption2).foregroundColor(.secondary)
        }
        Spacer()
    }
    .nnCard()
}
```
(When installed, show nothing extra — keeps the popover clean; full status UI is Spec B.)

**Step 2: Build**

```bash
swift build
```
Expected: clean build.

**Step 3: Commit**

```bash
git add Sources/App/ContentView.swift
git commit -m "feat(ui): show 'NoNoise Mic not installed' hint in the popover"
```

---

## Task 9: CI — driver compile + host unit tests

**Files:**
- Modify: `.github/workflows/ci.yml`

**Step 1: Add a job step** (after the existing swift build/test) that compiles the driver and runs the host C tests:

```yaml
      - name: Build NoNoise Mic driver (compile check)
        run: ./build-driver.sh
      - name: Run driver host unit tests (ring + clock)
        run: ./Driver/tests/run-tests.sh
```

**Step 2: Verify YAML locally**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
./Driver/tests/run-tests.sh && ./build-driver.sh
```
Expected: tests pass; driver builds. (CI runner is `macos-14` per existing workflow.)

**Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: compile NoNoise Mic driver + run host ring/clock tests"
```

---

## Task 10: Docs + `.gitignore`

**Files:**
- Modify: `README.md`, `AGENTS.md`, `.gitignore`, `docs/knowledge/timeline1.md`, `docs/knowledge/knowledge1.md`

**Step 1: `.gitignore`** — add the build artifact:
```
NoNoiseMic.driver/
```

**Step 2: `README.md`** — add a "NoNoise Mic (virtual microphone)" section: build (`./build-driver.sh`), install (`./install-driver.sh`, note the coreaudiod restart), select "NoNoise Mic" in Slack/Zoom/Meet/OBS, uninstall. Keep the BlackHole section as the documented fallback. Distinguish app-Gatekeeper (right-click-Open) from driver-load (coreaudiod signature check).

**Step 3: `AGENTS.md`** — add a "NoNoise Mic virtual driver" section: the shared-contract constants table, the topology (visible input + hidden engine, shared clock + ring), `sourceMode`, the "sign after assembly / verify on install" rules, and that the pure C (`nn_ring`/`nn_clock`) is the testable home for driver math (mirroring the "pure testable statics" rule).

**Step 4: `docs/knowledge/timeline1.md`** — prepend a dated entry summarizing Phase A1.

**Step 5: `docs/knowledge/knowledge1.md`** — add a `[GOTCHA]` about silent CFPlugIn non-load (bad `CFPlugInFactories`/`CFPlugInTypes` or post-sign edits) and the install-time verification that guards it.

**Step 6: Commit**

```bash
git add README.md AGENTS.md .gitignore docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document NoNoise Mic driver (install, contract, gotchas)"
```

---

## Task 11: Bundle integration + manual on-device verification

**Files:**
- Modify: `bundle.sh`

**Step 1: `bundle.sh --with-driver`** — add an optional flag that runs `./build-driver.sh` and stages `NoNoiseMic.driver` next to the app (build BEFORE signing the app; never copy into the signed app bundle afterward). Default (`./bundle.sh`) is unchanged.

**Step 2: Release build + bundle**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test && swift build -c release && ./bundle.sh --with-driver
```
Expected: tests pass, release builds, app + driver staged.

**Step 3: Manual on-device checklist (USER — can't run in CI)**
1. `./build-driver.sh && ./install-driver.sh` → prints `✅ NoNoise Mic installed and visible`.
2. Open **Audio MIDI Setup** → "NoNoise Mic" appears as an input; "NoNoise Mic Engine" does NOT appear (hidden).
3. Launch the app → no "not installed" hint; Output auto-selects (engine device, hidden from picker).
4. QuickTime → New Audio Recording → input "NoNoise Mic"; speak → hear your mic **cleaned** (AI on). Toggle AI off → passthrough.
5. Quit the app → recorder hears **silence** (not stale audio).
6. `./uninstall-driver.sh` → device gone after restart.

**Step 4: Commit**

```bash
git add bundle.sh
git commit -m "build: optional --with-driver staging in bundle.sh"
```

**Phase A1 done criteria:**
- [ ] `NoNoise Mic` installs, appears in consumer apps, carries cleaned audio; engine device hidden + non-default-eligible.
- [ ] App auto-routes to the engine device; virtual devices filtered from input + hidden from output picker.
- [ ] `swift test` green; `Driver/tests/run-tests.sh` green in CI; driver compiles in CI.
- [ ] Docs + manual checklist complete.

---

# PHASE A2 — XPC input-only + Settings toggle (GATED behind a spike)

> **HARD GATE:** Do NOT start Tasks 13+ until Task 12 (the spike) succeeds. If the spike shows coreaudiod's sandbox blocks the chosen mach-lookup even via a launchd helper, STOP and revisit the design with the user — A2 may need a different broker or stay loopback-only.

## Task 12: SPIKE — verify the XPC reachability (make-or-break)

**Goal:** Empirically confirm, on the target macOS (14/15), that a coreaudiod-hosted plug-in can reach a launchd-registered helper's mach service (BGM pattern), and that an FD passed over XPC can be `mmap`ed by the driver.

**Steps:**
1. Build a throwaway launchd helper that vends a trivial `NSXPCListener` mach service (`com.ivalsaraj.NoNoiseMic.helper`); register via a `LaunchDaemons` plist.
2. From the (installed, loopback) driver, attempt `xpc_connection_create_mach_service(...)` to the helper and send one message; log success/failure to Console.
3. From the app, `shm_open`+`mmap` a small region, pass its FD to the helper over XPC, have the helper forward it to the driver, and have the driver `mmap` the received FD and read a sentinel value the app wrote.
4. Record results in `docs/knowledge/knowledge1.md` as a `[DECISION]` (helper vs direct; any sandbox profile caveats).

**Gate:** ✅ all three succeed → proceed. ❌ any blocked → STOP, report to user.

**Commit:** the spike code under `Driver/spike/` (kept for reference) + the knowledge entry.

```bash
git add Driver/spike docs/knowledge/knowledge1.md
git commit -m "spike(driver): verify coreaudiod XPC helper reachability + FD-passed shm"
```

## Task 13: Shared-memory ring + atomic liveness header — TDD (host C)

Extend the pure C with a shared-memory layout: a header (`_Atomic uint64_t writeFrame; _Atomic uint32_t generation; uint32_t sampleRate, channels, capacityFrames;`) followed by the float storage. Reuse `nn_ring` wraparound math over the mapped storage. Host-test: producer writes + bumps `writeFrame`/`generation`; consumer reads trailing frames; a stale `generation` (no heartbeat) → consumer treats as "no client" (returns silence). Commit with tests.

## Task 14: launchd helper daemon (XPC broker)

Create `Helper/NoNoiseMicHelper/` (per the spike's chosen shape): an `NSXPCListener` mach service brokering app↔driver (FD handoff + start/stop). Add a `LaunchDaemons` plist; extend `install-driver.sh` to install + `launchctl bootstrap` it. Commit.

## Task 15: Driver — `sourceMode == xpc` IO path

In `DoIOOperation` (visible input), when `gSourceMode == 1`: read from the `mmap`ed shm ring at `mInputTime.mSampleTime`; if the shm `generation` is stale (no live writer), output silence. The `mmap` happens once when the helper hands the FD over (store the mapped pointer in a file-scope atomic). Commit.

## Task 16: App — XPC client + manual-render PCM emission

In `xpc` mode the app does NOT bind an output device. Switch `AVAudioEngine` to manual-rendering mode (or attach an `AVAudioSinkNode` tap on the existing graph), write rendered 48 kHz stereo Float32 into the shm ring, and bump the liveness header each buffer. Connect to the helper, hand off the shm FD, and tear down (stop heartbeat) on quit so the driver falls back to silence. Add pure-logic tests where possible (e.g., heartbeat/teardown state machine). Commit.

## Task 17: Settings `sourceMode` toggle + persistence + default flip

Add a Settings control: *Automatic (XPC)* / *Compatibility (Loopback)*, persisted under `mv.sourceMode`. On change, set the driver's `'srcm'` property (via `AudioObjectSetPropertyData`) and switch the app's emission path. After on-device validation, change the default to `xpc`. Update `AudioModel` + `SettingsView`. Commit.

## Task 18: A2 docs + manual checklist

Update `README.md` (mode toggle), `AGENTS.md` (A2 architecture, helper, FD-shm, liveness), `docs/knowledge/`. Manual checklist: toggle modes live; verify clean audio in both; verify quit → silence in xpc mode; verify no stray output device in xpc mode. Commit.

**Phase A2 done criteria:**
- [ ] Spike passed and recorded.
- [ ] `sourceMode` toggle works live; xpc mode shows no output device; bulk audio rides shm (not XPC).
- [ ] Quit → driver serves silence (atomic liveness, not XPC invalidation).
- [ ] Default flipped to xpc after validation; loopback remains as compatibility fallback.

---

## Execution notes
- **Commit cadence:** one atomic commit per task step group as shown; never `git add -A`.
- **Real-time discipline:** `DoIOOperation` and the app's render/emission path stay allocation-free, lock-free, syscall-free (matches `AGENTS.md`).
- **Docs land with behavior** (per `AGENTS.md` 8-fold awareness): each task that changes behavior updates the relevant doc in the same task.
- **Verification before "done":** `swift build && swift test` + `./Driver/tests/run-tests.sh` + `./build-driver.sh` must all pass before declaring a phase complete; on-device checklists are the human gates.
