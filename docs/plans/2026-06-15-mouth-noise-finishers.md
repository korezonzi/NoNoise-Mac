# Mouth-Noise Finishers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two new "mouth-noise finisher" stages to the `VoiceChain`: a **De-plosive** and a **De-click**. Together they complete the mouth-noise suppression suite — the de-esser (sibilance, already covered in `docs/plans/2026-06-15-broadcast-voice-clarity.md`) handles "ess/sh"; the de-plosive handles P/B pops and low-frequency thumps; the de-click handles short mouth clicks and lip-smacks. Both are **identity at rest** — they produce exactly `out == in` when no artifact is present — and both live as allocation-free, per-sample scalar types in `Dynamics.swift`, wired as new `VoiceChain` stages, gated by a single `MouthNoiseLevel` enum, and persisted under `mv.*`.

**Architecture:** Two new pure DSP value types (`DePlosive`, `DeClick`) appended to `Sources/Core/AudioProcessing/Dynamics.swift`. A `MouthNoiseLevel` enum (Off/Low/Medium/High, exactly mirroring `ClarityLevel`) added to `Sources/Core/AudioProcessing/VoiceChain.swift`. Carried on `VoiceChainSettings`, injected by `AudioModel.applyVoiceChain()` (independent of the noise preset, Voice Polish, and Broadcast Voice). Chain order: HP → shelves → presence → de-esser → **de-plosive → de-click** → compressor → limiter. When `mouthNoise == .off`, both stages are perfect identity — byte-for-byte unchanged for all existing presets. A single new persist key `mv.mouthNoise`. Exposed via a segmented picker in Settings and the popover.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, scalar math (no Accelerate dependency in any new type).

**Execution location:** Run all commands from the package root — the directory that contains `Package.swift`. All paths in this plan are relative to that root.

---

## Context

### Why these stages

The de-esser (already planned in Broadcast Voice) removes sibilant hiss on consonants. But real-world voice recordings suffer from two more categories of mouth noise that EQ and de-essing cannot reach:

1. **Plosives (P-pops / B-thumps):** A sharp wideband transient + a low-frequency pressure wave at mic impact. The signature is a brief burst of sub-100 Hz energy followed by a broadband click. Classic hardware fix is a pop filter; we replicate that logic in DSP: detect the low-band transient onset and transiently high-pass / duck the low band. The vocal mid-range (where intelligibility lives) is untouched.

2. **Mouth clicks / lip-smacks:** Very short (< 10 ms) broadband transients that are NOT sibilants — they contain significant energy below the de-esser's 6 kHz crossover. They arise from dry lips, mouth moisture, or dental contact. The fix is a short transient detector that spots an anomalously fast rise in broadband energy and applies a brief (3–8 ms) broadband gain reduction — too short to color the voice but long enough to mask the click.

Both stages share the same invariant as the de-esser: **out == in when no artifact is present**. This is enforced structurally and proven in every test.

### The non-negotiable constraint: PRESERVE THE ORIGINAL VOICE

This plan satisfies it structurally, not by taste alone:

1. **De-plosive — identity at rest.** The plosive detector watches the ratio of low-band energy to total energy (`low / total`). During normal voiced phonemes this ratio stays within a broad normal range — only a plosive transient drives it anomalously high while simultaneously above a total-energy threshold. Below threshold, `gain = 1.0` exactly — no subtraction, no filter insertion, no coloration. The gain taper (attack 0.3 ms, release 25 ms) is fast enough to catch the pop and short enough to release before the following vowel is colored.

2. **De-click — identity at rest.** The click detector watches instantaneous broadband energy relative to a slow background RMS. A mouth click appears as a sudden spike `> clickRatio × background`. Outside that spike, `gain = 1.0` exactly. The hold time (≤ 5 ms) ensures that even a consonant burst that triggers the detector recovers before affecting the following vowel.

3. **Conservative, capped gain reduction even at High** (de-plosive: up to 18 dB; de-click: up to 12 dB) to never destroy the transient character of voiced stops (B, D, G) that are NOT pops.

4. **`mouthNoise == .off` is a true no-op.** Both types return `x` unchanged when disabled, and both `configure` arms call `setBypass()` on any internal biquads and zero all state — so existing Meeting/Podcast/Tutorial/Custom presets behave **byte-for-byte as before**.

### Current code facts (verified against the repo)

- `Biquad` (`Sources/Core/AudioProcessing/Biquad.swift`): `setBypass / setHighPass / setLowShelf / setHighShelf / setPeaking`, per-sample `process`, `dcGain` test helper, `reset()`. Already fully sufficient; no new methods needed.
- `Dynamics.swift` has `Compressor`, `Limiter`, and `DeEsser` (added by the Broadcast Voice plan). **No de-plosive or de-click** — this plan adds both.
- `VoiceChain.swift`: `VoiceChainSettings` (value struct, `Sendable, Equatable`), `ClarityLevel` (Off/Low/Medium/High), `ClarityProfile` constants, and the `VoiceChain` class. Current chain order (after Broadcast Voice): HP → lowShelf → highShelf → presence → de-esser → compressor → limiter. This plan inserts de-plosive and de-click between de-esser and compressor.
- `AudioModel.swift` (`Sources/Core/AudioModel.swift`): `@Published var clarityLevel` (persisted `mv.clarity`), injected via `applyVoiceChain()`. The `PrefKey` enum, `persistSettings()`, and `loadSettings()` are the persistence triad — one new key and one new property follows the exact same pattern.
- `VoiceChainSettings`: value struct; adding a new `var mouthNoiseLevel: MouthNoiseLevel = .off` with a default keeps the synthesized memberwise initializer backward-compatible (existing callers don't name `mouthNoiseLevel`).
- Tests: `Tests/NoNoiseMacTests/BroadcastVoiceTests.swift` is the style reference for the new test class (`Tests/NoNoiseMacTests/MouthNoiseTests.swift`). Headless XCTest, `@testable import Core`.
- UI: `SettingsView.swift` → `GeneralSettingsView.suppressionCard` has the Voice Polish toggle and the Broadcast Voice picker. The new control goes below Broadcast Voice, following the same `Divider / VStack / Picker / Text(caption)` pattern. `ContentView.swift` has `clarityCard` (added by Broadcast Voice plan). A new `mouthNoiseCard` follows it with the same `cardLabel / Picker / nnCard()` pattern.

### Design decisions

- **`MouthNoiseLevel` mirrors `ClarityLevel` exactly.** Same four cases (Off/Low/Medium/High), same `label`, `id`, `allCases`. This keeps the Settings and popover UI consistent and avoids a special-cased on/off toggle.
- **Chain position: after de-esser, before compressor.** The de-esser has already removed sibilance; de-plosive and de-click operate on what's left. Running before the compressor means a plosive thump doesn't pump the compressor's envelope, and the compressor's makeup gain doesn't re-amplify a click artifact.
- **Single persisted key** (`mv.mouthNoise`); no other persistence changes.
- **One new file** for tests (`Tests/NoNoiseMacTests/MouthNoiseTests.swift`); all new DSP appended to `Dynamics.swift`.
- **`MouthNoiseProfile`** (internal `enum` in `VoiceChain.swift`) holds all fixed band/timing constants, following the `ClarityProfile` pattern.

### DSP design

#### De-plosive

A plosive is a wideband transient where the sub-100 Hz band is disproportionately energetic (the pressure wave). Detection strategy:

1. A **low-band energy follower** tracking `|lowHP|^2` via one-pole smoothing (attack 0.1 ms, release 40 ms), where `lowHP` is the output of a Butterworth-style low-pass at ~120 Hz. We use a Biquad low-shelf at 120 Hz with gain 0 dB (no gain, just to isolate the low band) — or more precisely a second Biquad high-pass inverted: `low = x - hp(x)`. Implementation: store `lpSig = x - hp.process(x)` where `hp` is a 120 Hz high-pass.
2. A **total-energy follower** tracking `|x|^2` via the same attack/release.
3. **Plosive condition**: `lowEnv > plosThreshold && lowEnv > plosRatio × totalEnv`. The second condition (`lowRatio > plosRatio`) distinguishes a plosive (bottom-heavy) from a uniform transient (click or consonant burst).
4. When condition fires: apply a gain ramp to the **low-band signal** only — subtract `frac × lowSig` from `x`, exactly like the de-esser's subtractive pattern: `out = x - frac * lowSig`. `frac` ramps from 0 at threshold to `maxPlosReduction` above it, via the same `1 - 1/over` shape.

This is subtractive and identity at rest: when `lowEnv <= plosThreshold`, `frac = 0`, `out = x` exactly.

#### De-click

A mouth click is a very short broadband transient — sharp rise in ALL frequency bands simultaneously. Detection:

1. A **fast envelope** tracking `|x|` with attack 0.05 ms, release 2 ms (near-instantaneous).
2. A **slow background RMS** tracking `|x|` with attack 50 ms, release 200 ms (tracks the speech body, not transients).
3. **Click condition**: `fastEnv > clickRatio × slowEnv && fastEnv > minClickThreshold`. The ratio test ensures clicks are detected relative to the local speech level — so a loud speaker doesn't suppress every voiced stop.
4. When condition fires: set `clickGain` toward `clickGainFloor` (instantaneous attack); `clickGain` releases back to 1.0 over `holdAndRelease` ms (3–5 ms). Apply: `out = x × clickGain`.

Identity at rest: when `fastEnv <= clickRatio × slowEnv`, `clickGain = 1.0`, `out = x` exactly.

### Level → DSP mapping (the whole feature in one table)

| Level | De-plosive max reduction | De-click max gain floor |
|---|---|---|
| **Off** | 0 (identity) | 1.0 (identity) |
| **Low** | 8 dB | 0.50 (−6 dB) |
| **Medium** | 14 dB | 0.35 (−9 dB) |
| **High** | 20 dB | 0.25 (−12 dB) |

Fixed constants (`MouthNoiseProfile`): plosive LP/split 120 Hz; plosive threshold −42 dBFS; plosive low-ratio guard 0.60; plosive attack 0.3 ms, release 25 ms. Click fast-attack 0.05 ms, fast-release 2 ms; click slow-attack 50 ms, slow-release 200 ms; click ratio 6.0×; click min-threshold −54 dBFS; click hold-release 4 ms.

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch**

```bash
git checkout -b feat/mouth-noise-finishers
```

Expected: `Switched to a new branch 'feat/mouth-noise-finishers'`. Throughout this plan, `git add` **only the specific files named in each task** — never `git add -A`/`.`.

---

## Task 1: `DePlosive` — subtractive low-band plosive gate — TDD

A per-sample, allocation-free plosive suppressor. Below threshold (and when disabled) it is a perfect identity. The test suite proves: disabled identity, below-threshold identity, plosive reduction, and that normal voiced mid-band content is untouched.

**Files:**
- Modify: `Sources/Core/AudioProcessing/Dynamics.swift` (append `DePlosive`)
- Create: `Tests/NoNoiseMacTests/MouthNoiseTests.swift`

### Step 1: Write the failing tests — create `Tests/NoNoiseMacTests/MouthNoiseTests.swift`

- [ ] Create `Tests/NoNoiseMacTests/MouthNoiseTests.swift` with the following content:

```swift
import XCTest
@testable import Core

final class MouthNoiseTests: XCTestCase {

    // MARK: - DePlosive

    /// Disabled de-plosive is a perfect identity for arbitrary samples.
    func testDePlosiveDisabledIsIdentity() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99, -0.01] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7,
                           "disabled de-plosive must not alter samples")
        }
    }

    /// Below-threshold sub-bass is a perfect identity (quiet hum does not trigger).
    func testDePlosiveBelowThresholdIsIdentity() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            // 80 Hz sine at −54 dBFS (well below the −42 dB threshold)
            let x = 0.002 * sinf(2 * Float.pi * 80 * Float(i) / 48000)
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 1e-4,
                          "below-threshold sub-bass must pass unchanged")
    }

    /// A loud, bottom-heavy low-band burst (simulating a P-pop) is attenuated.
    func testDePlosiveReducesLoudLowBandBurst() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var inSq: Float = 0, outSq: Float = 0
        let n = 9600, half = 2400   // measure 2nd half (settled detection)
        for i in 0..<n {
            // 60 Hz dominant + tiny 500 Hz harmonic → strong low-ratio bias
            let x = 0.7 * sinf(2 * Float.pi * 60  * Float(i) / 48000)
                  + 0.05 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            let y = d.process(x)
            if i >= half { inSq += x * x; outSq += y * y }
        }
        let measured = n - half
        XCTAssertLessThan(sqrtf(outSq / Float(measured)),
                          sqrtf(inSq / Float(measured)) * 0.80,
                          "loud plosive-shaped signal must be attenuated by at least 2 dB")
    }

    /// Mid-frequency voiced content (500 Hz, loud) is NOT suppressed — the de-plosive
    /// must leave normal speech energy intact even when `enabled`.
    func testDePlosivePreservesMidBandVoice() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            // 500 Hz sine at 0.5 amplitude — clear speech energy, not a plosive
            let x = 0.5 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 0.05,
                          "mid-band voice must not be significantly altered by the de-plosive")
    }

    // MARK: - DeClick

    /// Disabled de-click is a perfect identity.
    func testDeClickDisabledIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7,
                           "disabled de-click must not alter samples")
        }
    }

    /// Steady speech (not a click) — ratio never trips — passes through unchanged.
    func testDeClickSteadySpeechIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Run a 200 Hz sine for 1 s so the slow background settles.
        var maxDelta: Float = 0
        let settleSamples = 48000
        for i in 0..<settleSamples {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            // Measure only after settling (second half)
            if i >= settleSamples / 2 {
                maxDelta = max(maxDelta, abs(y - x))
            }
        }
        XCTAssertLessThan(maxDelta, 0.01,
                          "steady speech must not be attenuated by the de-click")
    }

    /// A short spike (simulating a lip-smack) is attenuated while the steady
    /// background preceding/following it is untouched.
    func testDeClickReducesShortSpike() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Settle the slow background with quiet speech for 0.5 s
        for i in 0..<24000 {
            _ = d.process(0.05 * sinf(2 * Float.pi * 200 * Float(i) / 48000))
        }
        // Inject a single-sample spike at 10× background (well past clickRatio × slow)
        let spikeSample: Float = 0.5   // >> 6 × 0.05
        let spikeOut = d.process(spikeSample)
        // The output must be significantly below the input spike
        XCTAssertLessThan(abs(spikeOut), abs(spikeSample) * 0.7,
                          "de-click must attenuate a short spike above the ratio threshold")
    }

    /// After the spike, the hold-release window expires and `gain` returns to ≥ 0.95
    /// within 20 ms — proving the de-click does NOT color normal speech that follows.
    func testDeClickReleasesQuickly() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Settle background
        for i in 0..<24000 {
            _ = d.process(0.05 * sinf(2 * Float.pi * 200 * Float(i) / 48000))
        }
        // Spike
        _ = d.process(0.5)
        // 20 ms of silence (960 samples) — gain must recover
        let releaseWindow = 960
        var finalGain: Float = 0
        for _ in 0..<releaseWindow {
            let x: Float = 0.05
            let y = d.process(x)
            finalGain = y / x   // gain = out/in when in != 0
        }
        XCTAssertGreaterThan(finalGain, 0.95,
                             "de-click gain must recover to near-unity within 20 ms after spike")
    }

    // MARK: - MouthNoiseLevel

    func testMouthNoiseLevelOffIsZero() {
        XCTAssertEqual(MouthNoiseLevel.off.maxPlosReductionDb, 0)
        XCTAssertEqual(MouthNoiseLevel.off.clickGainFloor, 1.0, accuracy: 1e-6)
    }

    func testMouthNoiseLevelIsMonotonic() {
        XCTAssertLessThan(MouthNoiseLevel.low.maxPlosReductionDb,
                          MouthNoiseLevel.medium.maxPlosReductionDb)
        XCTAssertLessThan(MouthNoiseLevel.medium.maxPlosReductionDb,
                          MouthNoiseLevel.high.maxPlosReductionDb)
        XCTAssertGreaterThan(MouthNoiseLevel.low.clickGainFloor,
                             MouthNoiseLevel.medium.clickGainFloor)
        XCTAssertGreaterThan(MouthNoiseLevel.medium.clickGainFloor,
                             MouthNoiseLevel.high.clickGainFloor)
    }

    func testMouthNoiseLevelCasesAndLabels() {
        XCTAssertEqual(MouthNoiseLevel.allCases, [.off, .low, .medium, .high])
        XCTAssertEqual(MouthNoiseLevel.off.label, "Off")
        XCTAssertEqual(MouthNoiseLevel.high.label, "High")
    }

    func testMouthNoiseLevelHighCapped() {
        // High must not exceed 24 dB plosive reduction — aggressive defaults harm
        // voiced stops (B, D, G) that are NOT plosives.
        XCTAssertLessThanOrEqual(MouthNoiseLevel.high.maxPlosReductionDb, 24,
                                 "de-plosive must stay conservative to preserve voiced stops")
        // High gain floor must not go below −15 dB (= 0.177) — click suppression
        // this aggressive would also attenuate consonant bursts.
        XCTAssertGreaterThan(MouthNoiseLevel.high.clickGainFloor, 0.17,
                             "de-click floor must stay within safe range")
    }

    // MARK: - VoiceChain integration

    /// mouthNoise == .off + disabled chain == passthrough (regression guard).
    func testChainMouthNoiseOffIsPassthrough() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .off
        chain.configure(s)
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "off+off must not modify samples")
    }

    /// mouthNoise active with polish OFF still runs (de-plosive and de-click engage).
    func testMouthNoiseActiveWithPolishOff() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .high
        chain.configure(s)
        XCTAssertTrue(chain.isActive)
    }

    /// Higher level produces more reduction on a plosive-shaped signal (monotonic).
    func testHigherMouthNoiseLevelReducesMoreOnPlosive() {
        func plosiveRMS(_ level: MouthNoiseLevel) -> Float {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.mouthNoiseLevel = level
            chain.configure(s)
            // Plosive signal: strong 60 Hz + weak 500 Hz
            var buf = [Float](repeating: 0, count: 9600)
            for i in 0..<buf.count {
                buf[i] = 0.7 * sinf(2 * Float.pi * 60  * Float(i) / 48000)
                       + 0.05 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            }
            buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            var sq: Float = 0
            for i in 4800..<buf.count { sq += buf[i] * buf[i] }
            return sqrtf(sq / 4800)
        }
        // Higher level → more reduction → lower output RMS on a plosive-shaped signal
        XCTAssertGreaterThan(plosiveRMS(.low),  plosiveRMS(.medium))
        XCTAssertGreaterThan(plosiveRMS(.medium), plosiveRMS(.high))
    }

    /// Changing mouthNoiseLevel while chain is active resets mouth-noise stages.
    func testMouthNoiseLevelChangeResetsStages() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .high
        chain.configure(s)
        // Energize with a loud plosive-shaped burst
        var burst = [Float](repeating: 0, count: 4800)
        for i in 0..<burst.count {
            burst[i] = 0.9 * sinf(2 * Float.pi * 60 * Float(i) / 48000)
        }
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        // Switch level while chain is still active
        s.mouthNoiseLevel = .low
        chain.configure(s)
        // Silence in → no stale ringing
        var quiet = [Float](repeating: 0, count: 128)
        quiet.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertTrue(quiet.allSatisfy { abs($0) < 1e-4 },
                      "mouth-noise stages must reset on level change — no stale ringing")
    }

    /// mouthNoise == .off with an enabled (polish-on) preset must be bit-identical
    /// to the chain without the mouth-noise stages — proving Off is a true no-op.
    func testMouthNoiseOffMatchesLegacyChain() {
        // Use podcast preset — polish ON, mouthNoiseLevel defaults to .off.
        let s = VoicePreset.podcast.voiceChain
        XCTAssertEqual(s.mouthNoiseLevel, .off,
                       "preset voiceChain must default mouthNoiseLevel to .off")
        let chain = VoiceChain()
        chain.configure(s)

        // Reference: canonical chain without de-plosive/de-click stages.
        var hp = Biquad(), lo = Biquad(), hi = Biquad(), pres = Biquad()
        var deEss = DeEsser()
        var comp = Compressor(); var lim = Limiter()
        hp.setHighPass(freq: s.highPassHz, sampleRate: 48000)
        lo.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: 48000)
        hi.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: 48000)
        // clarity is .off on the podcast preset (Broadcast Voice is orthogonal)
        pres.setBypass()
        deEss.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 0,
                        attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: false)
        comp.configure(thresholdDb: s.compThresholdDb, ratio: s.compRatio,
                       attackMs: s.compAttackMs, releaseMs: s.compReleaseMs,
                       makeupDb: s.compMakeupDb, sampleRate: 48000)
        lim.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: 48000)

        var buf = [Float](repeating: 0, count: 4800)
        for i in 0..<buf.count { buf[i] = 0.3 * sinf(2 * Float.pi * 220 * Float(i) / 48000) }
        var ref = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        for i in 0..<ref.count {
            var x = ref[i]
            x = hp.process(x); x = lo.process(x); x = hi.process(x)
            x = pres.process(x); x = deEss.process(x)
            x = comp.process(x); x = lim.process(x)
            ref[i] = x
        }
        for i in 0..<buf.count {
            XCTAssertEqual(buf[i], ref[i], accuracy: 1e-6,
                           "mouthNoise Off must equal canonical chain @\(i)")
        }
    }
}
```

### Step 2: Run tests to verify failure

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: compile error — `cannot find 'DePlosive' in scope`, `cannot find 'DeClick' in scope`, `cannot find 'MouthNoiseLevel' in scope`.

### Step 3: Implement `DePlosive` — append to `Sources/Core/AudioProcessing/Dynamics.swift`

- [ ] Append to `Sources/Core/AudioProcessing/Dynamics.swift`:

```swift
/// Subtractive low-band de-plosive. Detects P-pop / B-thump transients by
/// tracking the ratio of low-band energy (< `splitHz`) to total energy, and
/// subtractively removes a fraction of the low band when both the total energy
/// and the low-band ratio exceed their respective thresholds:
///   `out = x - frac·lowSig`
/// Below threshold (and when disabled) `frac = 0`, so `out = x` exactly —
/// the mid-range voice body and consonant bursts pass through untouched.
public struct DePlosive {
    // Low-band split: the "low" signal is `x - hp(x)`.
    private var hp = Biquad()           // high-pass at `splitHz` to isolate lo band
    private var enabled = false
    private var thresholdLin: Float = 1 // total-energy threshold (linear amplitude)
    private var lowRatioGuard: Float = 0.60  // lo/(lo+hi) must exceed this to flag plosive
    private var maxReduction: Float = 0      // max fraction of lowSig to subtract (0…1)
    private var attackCoeff: Float = 0
    private var releaseCoeff: Float = 0
    private var totalEnv: Float = 0     // smoothed |x| total-energy envelope
    private var lowEnv: Float = 0       // smoothed |lowSig| envelope

    public init() {}

    public mutating func configure(splitHz: Float, thresholdDb: Float, lowRatioGuard: Float,
                                   maxReductionDb: Float, attackMs: Float, releaseMs: Float,
                                   sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { hp.setBypass(); totalEnv = 0; lowEnv = 0; return }
        hp.setHighPass(freq: splitHz, sampleRate: sampleRate, q: 0.707)
        thresholdLin = powf(10, thresholdDb / 20)
        self.lowRatioGuard = max(0, min(1, lowRatioGuard))
        maxReduction = min(1, 1 - powf(10, -abs(maxReductionDb) / 20))
        attackCoeff  = expf(-1.0 / (max(attackMs,  0.01) * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { totalEnv = 0; lowEnv = 0; hp.reset() }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let hiSig = hp.process(x)
        let lowSig = x - hiSig          // low-band component (below splitHz)

        // Update envelope followers.
        let totalMag = abs(x)
        let lowMag   = abs(lowSig)
        let tCoeff = totalMag > totalEnv ? attackCoeff : releaseCoeff
        let lCoeff = lowMag   > lowEnv   ? attackCoeff : releaseCoeff
        totalEnv = tCoeff * totalEnv + (1 - tCoeff) * totalMag
        lowEnv   = lCoeff * lowEnv   + (1 - lCoeff) * lowMag

        // Detect plosive: total energy must exceed threshold AND the low band must
        // dominate (low/(low+high) > lowRatioGuard) to avoid suppressing consonant bursts.
        guard totalEnv > thresholdLin else { return x }
        let loRatio = lowEnv / (lowEnv + abs(hp.process(0)) + 1e-12) // forward peek without advancing state
        // Simpler and allocation-free: compute ratio from already-computed envelopes.
        let ratio = lowEnv / (totalEnv + 1e-12)
        guard ratio >= lowRatioGuard else { return x }

        // Subtractive low-band reduction (same shape as DeEsser.process).
        let over = totalEnv / thresholdLin   // > 1
        let frac = maxReduction * (1 - 1 / over)
        return x - frac * lowSig
    }
}

/// Broadband transient gate for mouth clicks and lip-smacks. Tracks a fast
/// instantaneous envelope and a slow background RMS; when the fast/slow ratio
/// exceeds `clickRatio` AND the fast envelope exceeds `minThreshold`, a brief
/// gain reduction (`gainFloor`) is applied for `holdReleaseMs` milliseconds.
/// Below the ratio (and when disabled) `gain = 1.0` exactly — normal speech,
/// voiced stops, and consonant bursts are untouched.
public struct DeClick {
    private var enabled = false
    private var clickRatio: Float = 6.0       // fast/slow ratio to flag a click
    private var minThresholdLin: Float = 0    // absolute floor so quiet rooms don't trigger
    private var gainFloor: Float = 0.25       // minimum gain during a click event
    private var fastAttackCoeff: Float = 0
    private var fastReleaseCoeff: Float = 0
    private var slowAttackCoeff: Float = 0
    private var slowReleaseCoeff: Float = 0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0
    private var holdReleaseCoeff: Float = 0   // gain release after hold expires
    private var fastEnv: Float = 0
    private var slowEnv: Float = 1e-6         // non-zero initial to prevent div-by-zero at first sample
    private var gain: Float = 1.0

    public init() {}

    public mutating func configure(fastAttackMs: Float, fastReleaseMs: Float,
                                   slowAttackMs: Float, slowReleaseMs: Float,
                                   clickRatio: Float, minThresholdDb: Float,
                                   holdReleaseMs: Float, gainFloor: Float,
                                   sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { fastEnv = 0; slowEnv = 1e-6; gain = 1; holdCounter = 0; return }
        self.clickRatio = max(1, clickRatio)
        self.gainFloor = max(0, min(1, gainFloor))
        minThresholdLin = powf(10, minThresholdDb / 20)
        fastAttackCoeff  = expf(-1.0 / (max(fastAttackMs,  0.01) * 0.001 * sampleRate))
        fastReleaseCoeff = expf(-1.0 / (max(fastReleaseMs, 0.01) * 0.001 * sampleRate))
        slowAttackCoeff  = expf(-1.0 / (max(slowAttackMs,  0.01) * 0.001 * sampleRate))
        slowReleaseCoeff = expf(-1.0 / (max(slowReleaseMs, 0.01) * 0.001 * sampleRate))
        holdSamples = Int(max(holdReleaseMs, 0.01) * 0.001 * sampleRate)
        // Release from gainFloor → 1.0 over the same holdReleaseMs window.
        holdReleaseCoeff = expf(-1.0 / (max(holdReleaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() {
        fastEnv = 0; slowEnv = 1e-6; gain = 1; holdCounter = 0
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let mag = abs(x)

        // Fast envelope: tracks instantaneous amplitude.
        let fCoeff = mag > fastEnv ? fastAttackCoeff : fastReleaseCoeff
        fastEnv = fCoeff * fastEnv + (1 - fCoeff) * mag

        // Slow envelope: tracks the speech background.
        let sCoeff = mag > slowEnv ? slowAttackCoeff : slowReleaseCoeff
        slowEnv = sCoeff * slowEnv + (1 - sCoeff) * mag

        // Click detection: fast spike relative to slow background.
        let isClick = fastEnv > clickRatio * slowEnv && fastEnv > minThresholdLin

        if isClick {
            gain = gainFloor          // instantaneous attack to floor
            holdCounter = holdSamples // arm the hold
        } else if holdCounter > 0 {
            holdCounter -= 1
            // During hold: gain stays at floor (or wherever attack left it).
        } else {
            // Release back to unity.
            gain = holdReleaseCoeff * gain + (1 - holdReleaseCoeff) * 1.0
        }

        return x * gain
    }
}
```

### Step 4: Run tests to verify they still fail with the right error

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: compile error — `cannot find 'MouthNoiseLevel' in scope`. `DePlosive` and `DeClick` now exist; `MouthNoiseLevel` comes in Task 2.

### Step 5: Commit

- [ ] Stage and commit:

```bash
git add Sources/Core/AudioProcessing/Dynamics.swift Tests/NoNoiseMacTests/MouthNoiseTests.swift
git commit -m "feat(dsp): add DePlosive and DeClick DSP types (identity at rest)"
```

---

## Task 2: `MouthNoiseLevel` enum — TDD

The user-facing Off/Low/Medium/High control and its single-source-of-truth DSP mapping, plus the `MouthNoiseProfile` fixed constants.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift` (add enum + constants after `ClarityProfile`)
- `Tests/NoNoiseMacTests/MouthNoiseTests.swift` (tests already written in Task 1 — they reference `MouthNoiseLevel`)

### Step 1: Run tests to verify failure

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: compile error — `cannot find 'MouthNoiseLevel' in scope`.

### Step 2: Add `MouthNoiseLevel` and `MouthNoiseProfile` to `VoiceChain.swift`

- [ ] In `Sources/Core/AudioProcessing/VoiceChain.swift`, insert immediately after the closing brace of `ClarityProfile`:

```swift
/// "Mouth Noise Finisher" intensity. Controls the de-plosive (P-pop/thump suppressor)
/// and de-click (lip-smack/mouth-click suppressor) stages. `.off` is a true no-op —
/// both stages return `x` unchanged, and all existing presets are unaffected.
public enum MouthNoiseLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// Maximum de-plosive low-band reduction in dB. Intentionally conservative —
    /// voiced stops (B, D, G) share low-band energy with plosives; excess reduction
    /// dulls them. Starting points, tunable after listening.
    public var maxPlosReductionDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 8
        case .medium: return 14
        case .high:   return 20
        }
    }

    /// De-click gain floor (linear). How far the gain drops during a click event.
    /// `.off` = 1.0 (identity); lower = more suppression.
    public var clickGainFloor: Float {
        switch self {
        case .off:    return 1.0
        case .low:    return 0.50   // −6 dB
        case .medium: return 0.35   // ~−9 dB
        case .high:   return 0.25   // −12 dB
        }
    }
}

/// Fixed band/timing constants for the mouth-noise finisher stages (tunable starting points).
/// All values chosen conservatively — they target artifacts that are distinctly sharper or
/// more low-heavy than any voiced phoneme.
enum MouthNoiseProfile {
    // De-plosive
    static let plosiveSplitHz: Float   = 120    // low/high split frequency
    static let plosiveThresholdDb: Float = -42  // total-energy floor to arm detection
    static let plosiveLowRatioGuard: Float = 0.60  // low/(total) ratio gate
    static let plosiveAttackMs: Float  = 0.3
    static let plosiveReleaseMs: Float = 25

    // De-click
    static let clickFastAttackMs: Float  = 0.05
    static let clickFastReleaseMs: Float = 2.0
    static let clickSlowAttackMs: Float  = 50.0
    static let clickSlowReleaseMs: Float = 200.0
    static let clickRatio: Float         = 6.0  // fast/slow ratio to flag a click
    static let clickMinThresholdDb: Float = -54  // absolute floor (quiet rooms don't trigger)
    static let clickHoldReleaseMs: Float = 4.0  // how long to hold + release gain
}
```

### Step 3: Run tests to verify they pass

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: the `MouthNoiseLevel` tests pass (the chain integration tests fail because `VoiceChainSettings.mouthNoiseLevel` does not exist yet).

### Step 4: Commit

- [ ] Stage and commit:

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift Tests/NoNoiseMacTests/MouthNoiseTests.swift
git commit -m "feat(dsp): add MouthNoiseLevel enum and MouthNoiseProfile constants"
```

---

## Task 3: Wire `DePlosive` + `DeClick` into `VoiceChain` — TDD

Carry `mouthNoiseLevel` on `VoiceChainSettings`; add the two stages as stored properties; update `configure`, `reset`, and `process`; keep the chain active when only mouth-noise is on.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift`
- The integration tests in `Tests/NoNoiseMacTests/MouthNoiseTests.swift` were written in Task 1 and reference `VoiceChainSettings.mouthNoiseLevel` and `VoiceChain.isActive`.

### Step 1: Run to verify failure

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: compile errors — `value of type 'VoiceChainSettings' has no member 'mouthNoiseLevel'`.

### Step 2a: Add `mouthNoiseLevel` to `VoiceChainSettings`

- [ ] In `Sources/Core/AudioProcessing/VoiceChain.swift`, in `VoiceChainSettings`, add after `var limiterCeilingDb: Float`:

```swift
    public var limiterCeilingDb: Float
    public var clarity: ClarityLevel = .off
    public var mouthNoiseLevel: MouthNoiseLevel = .off
```

The defaulted property keeps the synthesized memberwise initializer backward-compatible — all existing callers construct `VoiceChainSettings` without naming `mouthNoiseLevel`, so they default to `.off` and need no edits.

### Step 2b: Add stored properties to `VoiceChain`

- [ ] In the `VoiceChain` class, alongside `presence` and `deEsser`, add:

```swift
    private var dePlosive = DePlosive()
    private var deClick = DeClick()
    private var mouthNoise: MouthNoiseLevel = .off
```

### Step 2c: Update `configure(_:)` in `VoiceChain`

- [ ] In `configure(_:)`, update the active gate and the reset conditions:

The `active` gate becomes:
```swift
active = s.enabled || s.clarity != .off || s.mouthNoiseLevel != .off
```

The "clarity changed while active" partial-reset block expands to also reset mouth-noise stages when `mouthNoiseLevel` changes:

```swift
        } else if clarity != priorClarity {
            presence.reset(); deEsser.reset()
        } else if mouthNoise != priorMouthNoise {
            dePlosive.reset(); deClick.reset()
        }
```

Add the saved prior value:
```swift
        let priorMouthNoise = mouthNoise
```

At the end of `configure`, configure the new stages:
```swift
        mouthNoise = s.mouthNoiseLevel
        if mouthNoise != .off {
            dePlosive.configure(
                splitHz: MouthNoiseProfile.plosiveSplitHz,
                thresholdDb: MouthNoiseProfile.plosiveThresholdDb,
                lowRatioGuard: MouthNoiseProfile.plosiveLowRatioGuard,
                maxReductionDb: mouthNoise.maxPlosReductionDb,
                attackMs: MouthNoiseProfile.plosiveAttackMs,
                releaseMs: MouthNoiseProfile.plosiveReleaseMs,
                sampleRate: sampleRate, enabled: true)
            deClick.configure(
                fastAttackMs: MouthNoiseProfile.clickFastAttackMs,
                fastReleaseMs: MouthNoiseProfile.clickFastReleaseMs,
                slowAttackMs: MouthNoiseProfile.clickSlowAttackMs,
                slowReleaseMs: MouthNoiseProfile.clickSlowReleaseMs,
                clickRatio: MouthNoiseProfile.clickRatio,
                minThresholdDb: MouthNoiseProfile.clickMinThresholdDb,
                holdReleaseMs: MouthNoiseProfile.clickHoldReleaseMs,
                gainFloor: mouthNoise.clickGainFloor,
                sampleRate: sampleRate, enabled: true)
        } else {
            dePlosive.configure(splitHz: MouthNoiseProfile.plosiveSplitHz,
                                thresholdDb: -42, lowRatioGuard: 0.60,
                                maxReductionDb: 0, attackMs: 0.3, releaseMs: 25,
                                sampleRate: sampleRate, enabled: false)
            deClick.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                              slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                              holdReleaseMs: 4, gainFloor: 1.0,
                              sampleRate: sampleRate, enabled: false)
        }
```

### Step 2d: Update `reset()` in `VoiceChain`

- [ ] Extend `reset()` to include the new stages:

```swift
    public func reset() {
        hp.reset(); lowShelf.reset(); highShelf.reset()
        presence.reset(); deEsser.reset()
        dePlosive.reset(); deClick.reset()
        comp.reset(); limiter.reset()
    }
```

### Step 2e: Update `process(_:count:)` in `VoiceChain`

- [ ] Insert the two new stages between `deEsser` and `comp`. The chain order after this change is:

```
HP → lowShelf → highShelf → presence → deEsser → dePlosive → deClick → comp → limiter
```

The `process` loop becomes (replace the full function body):

```swift
    public func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        guard active else { return }
        let doPolish   = enabled
        let doClarity  = clarity != .off
        let doMouth    = mouthNoise != .off
        for i in 0..<count {
            var x = buffer[i]
            if doPolish {
                x = hp.process(x)
                x = lowShelf.process(x)
                x = highShelf.process(x)
            }
            if doClarity {
                x = presence.process(x)
                x = deEsser.process(x)
            }
            if doMouth {
                x = dePlosive.process(x)
                x = deClick.process(x)
            }
            if doPolish {
                x = comp.process(x)
            }
            x = limiter.process(x)
            buffer[i] = x
        }
    }
```

### Step 3: Run the full test suite

- [ ] Run: `swift test`
  - Expected: ALL tests pass — the new `MouthNoiseTests` suite AND the existing `VoiceChainTests` (regression) AND `BroadcastVoiceTests` (no interaction regression).

### Step 4: Commit

- [ ] Stage and commit:

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift
git commit -m "feat(dsp): wire DePlosive + DeClick into VoiceChain, gated by MouthNoiseLevel"
```

---

## Task 4: Wire `mouthNoiseLevel` into `AudioModel`

Expose the control as a persisted `@Published` property and inject it into the chain on top of the active preset. **No XCTest:** `AudioModel` depends on CoreAudio/AVCapture and is not unit-testable in the headless suite. Verification is `swift build` + the green Core suite + the manual smoke test at the end.

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

### Step 1: Add the `PrefKey`

- [ ] In the `PrefKey` enum (currently listing `preset`, `strength`, `atten`, `gain`, `voicePolish`, `clarity`), add:

```swift
        static let mouthNoise = "mv.mouthNoise"
```

### Step 2: Add the `@Published` property

- [ ] Immediately after the `clarityLevel` property, add:

```swift
    /// Mouth-noise finisher level (de-plosive + de-click). Layered on top of the
    /// active preset, independent of the noise preset, Voice Polish, and Broadcast
    /// Voice. Guarded by `isApplyingPreset` like all other knobs.
    @Published public var mouthNoiseLevel: MouthNoiseLevel = .off {
        didSet {
            guard !isApplyingPreset else { return }
            applyVoiceChain()
            persistSettings()
        }
    }
```

### Step 3: Inject in `applyVoiceChain()`

- [ ] Modify `applyVoiceChain()`:

```swift
    private func applyVoiceChain() {
        var s = selectedPreset.voiceChain
        s.enabled = s.enabled && voicePolishEnabled
        s.clarity = clarityLevel
        s.mouthNoiseLevel = mouthNoiseLevel
        voiceChain.configure(s)
    }
```

### Step 4: Persist + restore

- [ ] In `persistSettings()`, add after the `clarityLevel` persist line:

```swift
        d.set(clarityLevel.rawValue, forKey: PrefKey.clarity)
        d.set(mouthNoiseLevel.rawValue, forKey: PrefKey.mouthNoise)
```

- [ ] In `loadSettings()`, restore inside the `isApplyingPreset = true … = false` block, right after the `clarityLevel` restore:

```swift
        clarityLevel = ClarityLevel(rawValue: d.string(forKey: PrefKey.clarity) ?? "") ?? .off
        mouthNoiseLevel = MouthNoiseLevel(rawValue: d.string(forKey: PrefKey.mouthNoise) ?? "") ?? .off
        selectedPreset = preset
```

### Step 5: Build + regression test

- [ ] Run: `swift build && swift test`
  - Expected: build succeeds; all tests PASS.

### Step 6: Commit

- [ ] Stage and commit:

```bash
git add Sources/Core/AudioModel.swift
git commit -m "feat(audio): persist + apply MouthNoiseLevel (de-plosive + de-click) on top of presets"
```

---

## Task 5: Settings UI — Mouth Noise picker

Add the control to `GeneralSettingsView.suppressionCard`, directly under the Broadcast Voice picker. **No XCTest** (SwiftUI view) — verify by build + manual.

**Files:**
- Modify: `Sources/App/SettingsView.swift`

### Step 1: Add the picker

- [ ] Inside `suppressionCard`, after the closing brace of the Broadcast Voice `VStack` block (and before the closing `}` of the `suppressionCard` VStack), add:

```swift
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Mouth Noise").font(.subheadline)
                Picker("", selection: $audioModel.mouthNoiseLevel) {
                    ForEach(MouthNoiseLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Tames P-pops and lip-smacks. De-plosive ducks low-band thumps; de-click masks short mouth clicks. Off = no processing added.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
```

### Step 2: Build

- [ ] Run: `swift build`
  - Expected: build succeeds.

### Step 3: Commit

- [ ] Stage and commit:

```bash
git add Sources/App/SettingsView.swift
git commit -m "feat(ui): add Mouth Noise level picker to Settings"
```

---

## Task 6: Popover UI — compact Mouth Noise card

Add a compact picker to the menu-bar popover below the Broadcast Voice card (which is below `modeCard`). **No XCTest** — build + manual.

**Files:**
- Modify: `Sources/App/ContentView.swift`

### Step 1: Add `mouthNoiseCard`

- [ ] After the `clarityCard` computed view, add:

```swift
    // MARK: - Mouth Noise finishers

    private var mouthNoiseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardLabel("Mouth Noise", systemImage: "mouth.fill")
            Picker("", selection: $audioModel.mouthNoiseLevel) {
                ForEach(MouthNoiseLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .nnCard()
    }
```

### Step 2: Place in the layout

- [ ] In `body`'s `VStack`, add `mouthNoiseCard` after `clarityCard`:

```swift
        VStack(spacing: 14) {
            header
            statusCard
            modeCard
            clarityCard
            mouthNoiseCard
            devicesCard
            driverStatusRow
            footer
        }
```

### Step 3: Build

- [ ] Run: `swift build`
  - Expected: build succeeds.

### Step 4: Commit

- [ ] Stage and commit:

```bash
git add Sources/App/ContentView.swift
git commit -m "feat(ui): add compact Mouth Noise card to menu-bar popover"
```

---

## Task 7: Documentation (8-Fold Awareness Step 2 + compounding)

**Files:**
- Modify: `README.md`
- Modify: `CONCEPTS.md`
- Modify: `AGENTS.md`
- Modify: `docs/knowledge/timeline1.md`
- Modify: `docs/knowledge/knowledge1.md`

### Step 1: `README.md`

- [ ] Add a feature bullet under the Broadcast Voice bullet:

```markdown
- **🫦 Mouth Noise** — an optional de-plosive (P-pop / B-thump suppressor) and de-click (lip-smack / mouth-click suppressor) stage (Off / Low / Medium / High). Both are identity at rest — only the artifact is removed, never the voice.
```

- [ ] Add a short subsection after the Broadcast Voice section:

```markdown
### 🫦 Mouth Noise

Two targeted artifact suppressors that live after the de-esser in the chain:

- **De-plosive**: detects P-pop / B-thump transients by watching the ratio of low-band energy (< 120 Hz) to total energy. Only subtractively ducks the low band when both the energy level and the low-heavy ratio exceed their thresholds — so normal voiced stops (B, D, G) pass through untouched.
- **De-click**: tracks a fast envelope vs. a slow background RMS. When the fast/slow ratio spikes beyond `clickRatio` (6×), a brief (4 ms) gain reduction is applied. Normal speech never sustains this ratio.

Both stages are **Off by default** and are **identity at rest** — verified by XCTest. They are orthogonal to Broadcast Voice and the noise preset.
```

### Step 2: `CONCEPTS.md`

- [ ] Append to the voice-chain concept section:

```markdown
- **Mouth Noise Finishers** — two identity-at-rest DSP stages after the de-esser:
  - **De-plosive** (`DePlosive`): subtractive low-band gate. `out = x − frac·lowSig`
    when the low-band ratio and total energy both exceed thresholds. Identity otherwise.
  - **De-click** (`DeClick`): broadband transient gate. `out = x × gain` where
    `gain < 1` only during brief (< 5 ms) fast/slow envelope ratio spikes. Identity otherwise.
  - Controlled by `MouthNoiseLevel` (off/low/medium/high); persisted under `mv.mouthNoise`.
```

### Step 3: `AGENTS.md`

- [ ] Update the architecture-map bullet for the voice chain:

Find the line recently updated by the Broadcast Voice plan:
```
  - `AudioProcessing/VoiceChain` + `Biquad` + `Dynamics` — post-DSP "voice polish" (high-pass → shelves → compressor → limiter) plus the optional **Broadcast Voice** clarity stages (presence peaking bell → subtractive `DeEsser`), driven by `ClarityLevel` and gated independently of the noise preset.
```
Replace with:
```
  - `AudioProcessing/VoiceChain` + `Biquad` + `Dynamics` — post-DSP "voice polish" (high-pass → shelves → compressor → limiter) plus the optional **Broadcast Voice** clarity stages (presence peaking bell → subtractive `DeEsser`), and the optional **Mouth Noise** finisher stages (subtractive `DePlosive` → broadband-gate `DeClick`). Driven by `ClarityLevel` + `MouthNoiseLevel`, each gated independently of the noise preset.
```

- [ ] Update the chain-order bullet in the "Voice polish chain (Tier 2)" section:

Find:
```
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → **presence (peaking bell) → de-esser** → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
```
Replace with:
```
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → **presence (peaking bell) → de-esser → de-plosive → de-click** → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
```

- [ ] Update the persistence/activation bullet:

Find:
```
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage) plus the orthogonal **Broadcast Voice** `ClarityLevel`. The chain runs when `(voicePolishEnabled && preset.voiceChain.enabled) || clarity != .off`. Meeting polish = off; Podcast/Tutorial/Custom = on; Broadcast Voice (presence + de-esser) layers on any mode. Persisted: `mv.voicePolish`, `mv.clarity` (plus the Tier 1 `mv.preset`). `configure` resets ALL stage state on inactive→active, and resets ONLY the clarity stages when `clarity` changes while the chain stays active (bumpless otherwise).
```
Replace with:
```
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage) plus the orthogonal **Broadcast Voice** `ClarityLevel` and **Mouth Noise** `MouthNoiseLevel`. The chain runs when `(voicePolishEnabled && preset.voiceChain.enabled) || clarity != .off || mouthNoise != .off`. Meeting polish = off; Podcast/Tutorial/Custom = on; Broadcast Voice (presence + de-esser) and Mouth Noise (de-plosive + de-click) layer on any mode independently. Persisted: `mv.voicePolish`, `mv.clarity`, `mv.mouthNoise` (plus the Tier 1 `mv.preset`). `configure` resets ALL stage state on inactive→active; resets ONLY clarity stages when `clarity` changes while active; resets ONLY mouth-noise stages when `mouthNoiseLevel` changes while active (bumpless otherwise).
```

- [ ] Update the real-time rule bullet:

Find:
```
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2` for the high-pass, shelves, and the `presence` bell; `Compressor.envDb`; `Limiter.gain`; and the `DeEsser`'s detector envelope + high-pass state) carries across render buffers — never reset per buffer. `configure` resets state in exactly two cases: a FULL reset on the inactive→active transition (clean start), and a clarity-stages-only reset (`presence` + `DeEsser`) when `ClarityLevel` changes while the chain stays active. Active→active switches with unchanged clarity are intentionally bumpless.
```
Replace with:
```
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2` for the high-pass, shelves, and presence bell; `Compressor.envDb`; `Limiter.gain`; `DeEsser` envelope + HP state; `DePlosive` envelope pair + HP state; `DeClick` fast/slow envelopes, gain, hold counter) carries across render buffers — never reset per buffer. `configure` resets state in exactly three cases: FULL reset on inactive→active (clean start); clarity-stages-only reset (`presence` + `DeEsser`) when `ClarityLevel` changes while active; mouth-noise-stages-only reset (`DePlosive` + `DeClick`) when `MouthNoiseLevel` changes while active. All other active→active switches are intentionally bumpless.
```

### Step 4: `docs/knowledge/timeline1.md`

- [ ] Append a dated entry at the top (newest on top per the file's convention):

```markdown
### 2026-06-15 — Mouth-Noise Finishers (de-plosive + de-click) added

Added two new identity-at-rest `VoiceChain` stages after the de-esser:
`DePlosive` (subtractive low-band plosive gate, `out = x − frac·lowSig`) and
`DeClick` (broadband transient gate, `out = x × gain`). Both are pure value types
in `Dynamics.swift`, gated by `MouthNoiseLevel` (off/low/medium/high) carried on
`VoiceChainSettings` and injected by `AudioModel.applyVoiceChain()`. Persisted
under `mv.mouthNoise`. UI: segmented picker in Settings and the popover. Design
invariant — identity at rest — enforced structurally and proven by XCTest.
```

### Step 5: `docs/knowledge/knowledge1.md`

- [ ] Append a `[DECISION]` entry:

```markdown
### [DECISION] 2026-06-15 — Mouth-noise finishers: subtractive detection preserves voice character

**Problem**: P-pops and mouth clicks cannot be removed by EQ or de-essing alone — they
span the wrong frequency bands and timescales.
**Decision**: (1) `DePlosive` uses a dual-threshold detector (total energy AND low/total
ratio) to distinguish plosive thumps from voiced stops (B, D, G). Only when BOTH gates
fire does it subtractively duck the low band (`out = x − frac·lowSig`) — leaving the
mid-range voice body untouched. (2) `DeClick` uses a fast/slow envelope ratio — a click
appears as an anomalous spike relative to the speech background — and applies a hold-and-
release gain only for a few milliseconds, too brief to affect any voiced phoneme.
**Rule**: Any transient-targeted artifact suppressor must have a dual-gate (absolute
threshold + relative detection) and be tested for identity below threshold AND
preservation of the nearest voiced phoneme (voiced stop at the same level as the
artifact). Single-threshold detection is prone to false positives on consonant bursts.
**Files**: `Sources/Core/AudioProcessing/Dynamics.swift`,
`Sources/Core/AudioProcessing/VoiceChain.swift`,
`Tests/NoNoiseMacTests/MouthNoiseTests.swift`
```

### Step 6: Commit

- [ ] Stage and commit:

```bash
git add README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document Mouth Noise Finishers feature, vocab, chain order, and decision"
```

---

## Manual smoke test (after all tasks)

The headless suite cannot exercise the live audio path. After implementation, verify in the running app:

> **Note:** All voice-chain stages (including Mouth Noise) only run while **Noise Cancellation is ON** (`isAIEnabled = true`). Ensure that toggle is on for steps 3–6.

1. `./install-app.sh` (or `swift run`), open the popover.
2. Set a mode (e.g. Podcast). Speak naturally — confirm normal cleaned voice.
3. Set **Mouth Noise = Low**. Deliberately pop a few P's and B's directly into the mic. Confirm: the low-frequency thump is softened without the following vowel being colored.
4. Repeat step 3 with **Medium** and **High** — confirm increased suppression of the low-band pop while speech body is not affected.
5. Click your tongue / make a sharp lip-smack. Confirm: the click is softened at all levels, and the speech right after sounds normal.
6. Set **Mouth Noise = Off** — confirm sound is identical to before the feature (regression by ear).
7. Quit and relaunch — confirm the chosen level is restored (persistence).
8. Try Mouth Noise with **Meeting** mode (polish off) — confirm it still suppresses clicks/pops and never clips (limiter safety).
9. Enable both **Broadcast Voice = Medium** and **Mouth Noise = Medium** simultaneously. Speak, pop a few P's, make a click. Confirm: Broadcast Voice adds presence, Mouth Noise suppresses artifacts; neither stage interferes with the other audibly.

---

## Self-Review (completed during authoring)

- **Spec coverage:** "De-plosive: tame P-pops / low-frequency thumps via a transient-triggered dynamic high-pass / low-band ducking. Identity at rest." → `DePlosive` (Task 1), `MouthNoiseLevel` (Task 2), chain wiring (Task 3), AudioModel (Task 4), UI (Tasks 5–6). "De-click: suppress short mouth clicks / lip-smacks via a short-transient detector + brief targeted attenuation. Identity at rest." → `DeClick` (Task 1), same wiring path. "Identity at rest proven by tests" → `testDePlosiveDisabledIsIdentity`, `testDePlosiveBelowThresholdIsIdentity`, `testDeClickDisabledIsIdentity`, `testDeClickSteadySpeechIsIdentity`. "Only targeted artifact reduced, voice body untouched" → `testDePlosivePreservesMidBandVoice`, `testDeClickReleasesQuickly`. "Off = true no-op" → `testMouthNoiseOffMatchesLegacyChain`.
- **Placeholder scan:** none — every code step shows complete, copy-pasteable code.
- **Type consistency:** `MouthNoiseLevel` (with `maxPlosReductionDb`, `clickGainFloor`, `label`, `allCases`, `id`), `MouthNoiseProfile` constants, `DePlosive.configure(splitHz:thresholdDb:lowRatioGuard:maxReductionDb:attackMs:releaseMs:sampleRate:enabled:)`, `DeClick.configure(fastAttackMs:fastReleaseMs:slowAttackMs:slowReleaseMs:clickRatio:minThresholdDb:holdReleaseMs:gainFloor:sampleRate:enabled:)`, `VoiceChainSettings.mouthNoiseLevel`, and `AudioModel.mouthNoiseLevel` are used consistently across all tasks.
- **Interaction with existing stages:** chain position (de-plosive → de-click after de-esser, before compressor) prevents plosive thumps from pumping the compressor envelope. The de-esser's 6 kHz crossover is above the de-plosive's 120 Hz split — no frequency overlap; stages are independent.
- **Regression guard:** `testMouthNoiseOffMatchesLegacyChain` proves byte-for-byte identity when mouth noise is off. `testChainMouthNoiseOffIsPassthrough` proves no-op on a disabled chain. The existing `VoiceChainTests` run as part of `swift test` and catch any regressions in the polish stages.
- **No "MetalVoice"/"Ghostkwebb" in Sources/:** none introduced.
- **No absolute local paths:** all paths are repo-relative.
- **`mv.*` persistence:** `mv.mouthNoise` follows the existing pattern exactly.
