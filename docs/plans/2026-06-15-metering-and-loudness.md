# Metering & Loudness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one shared **render-thread telemetry layer** that publishes lock-free scalars, and build two synergistic features on top of it: (1) a **Live HUD** — input/output level, sample-peak + a CLIP indicator, an "AI working hard" confidence signal, and added latency in ms; and (2) an **integrated LUFS loudness meter** (ITU-R BS.1770 K-weighting) with an optional **target-loudness normalization** stage (−14 / −16 LUFS) bounded by a true-peak-style ceiling that extends the existing `Limiter`.

**Architecture:** A new pure value type **`LoudnessMeter`** (Core/AudioProcessing) implements BS.1770 K-weighting (high-shelf + high-pass `Biquad`) → mean-square → gated integration, plus sample-peak tracking — fully headless-testable. A new **`AudioTelemetry`** struct of plain lock-free scalars (mirroring the existing `DeepFilterNetDSP.outputGain` / `suppressionStrength` pattern — atomic 32-bit loads/stores on arm64, **no locks**) carries metering state from the render/DSP threads to the UI. The render callback writes input level, output level, sample-peak, clip count, added-latency, and (from `DeepFilterNetDSP`) an AI-confidence scalar derived from the model's per-bin gain reduction. A modest ~25 Hz `Timer` on `AudioModel` snapshots those scalars into `@Published` properties for SwiftUI. The HUD reuses `MeterView`; loudness normalization adds a pre-limiter auto-gain stage in `VoiceChain`, gated by a persisted `mv.*` toggle and target.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, Accelerate (per-sample scalar/biquad math; no CoreML dependency in any new pure type).

**GitHub Issue:** _(to be filled by github-issue-lifecycle Phase 1 before execution)_

**Execution location:** Run all commands from the package root — the directory that contains `Package.swift`. All paths in this plan are relative to that root.

---

## Context

### Why this feature
NoNoise Mac cleans the mic but gives the user **no feedback**: is my voice getting through? Is the AI actually suppressing anything, or is the room quiet? Am I clipping? Am I too quiet / too loud for the platform? Today the only signal is a single `inputLevel` RMS bar (`ContentView.MeterView`). Two creator-grade asks recur: a **Live HUD** that proves the pipeline is working (and warns on clipping), and a **loudness meter + normalization** so a streamer/podcaster lands near the platform target (−14 LUFS YouTube/Spotify, −16 LUFS Apple Podcasts) without manual gain-riding.

Both features want the **same data off the render thread** — levels, peaks, suppression activity. Building two ad-hoc paths would duplicate the unsafe main↔render plumbing. So this plan builds **one telemetry layer** first, then layers the HUD and the LUFS work on it.

### The non-negotiable constraint: the render thread stays allocation-free and lock-free
This plan satisfies it structurally (`docs/knowledge/critical-patterns.md` → "The render thread is allocation-free", "Suppression knobs are lock-free scalars (arm64)"):

1. **Telemetry is plain `Float`/`Int32` scalars**, written from the render/DSP threads and read from main — exactly the `outputGain` / `suppressionStrength` / `attenuationLimitDb` pattern. 32-bit aligned scalar load/store is atomic on arm64. **No locks, no `os_unfair_lock`, no queues** in the hot path.
2. **No allocation in `process`/`processHop`/the render callback.** Level/peak accumulation is scalar arithmetic over the existing in-place buffer; the AI-confidence accumulator reuses values already computed inside the per-bin blend loop.
3. **All BS.1770 / loudness math lives in a pure, headless-testable value type** (`LoudnessMeter`) with no CoreAudio/CoreML dependency — same rule as `Biquad`/`Compressor`/`resolveOutputBin`. `AudioModel` itself is **not** unit-tested (its `init()` starts CoreAudio/AVFoundation); it is verified by `swift build` + the green Core suite + the manual smoke test.
4. **UI refresh is modest (~25 Hz), not per-sample.** A single `Timer.publish`/`Timer.scheduledTimer` on the main run loop snapshots the scalars into `@Published` properties — no needless polling, no per-buffer main-thread hops (the existing per-callback `inputLevel` `DispatchQueue.main.async` is **replaced** by the timer snapshot to cut main-thread churn).

### Honest scope calls (stated up front, per the perf mandate)
- **Sample-peak + CLIP flag for v1, NOT oversampled true-peak.** True ITU-R BS.1770-4 true-peak requires ≥4× oversampling per channel on the render thread — too heavy for an always-on menu-bar utility on every buffer. v1 ships **sample-peak** detection plus a **clip indicator** (count of samples at/over a near-0 dBFS threshold). The loudness normalization ceiling is therefore a **sample-peak ceiling labeled −3 dB "peak"** (not certified dBTP). True-peak oversampling is explicitly deferred; the `LoudnessMeter` API leaves room to add it later without changing call sites. This is documented in the UI copy and in `CONCEPTS.md` so we never claim certified true-peak.
- **Integrated (gated) LUFS as the headline number; momentary LUFS as the live needle.** Full BS.1770 integrated loudness gates with an absolute −70 LUFS gate **and** a relative −10 LU gate over the whole program — the relative gate needs the running mean of block loudnesses, which we keep as a streaming accumulator (no unbounded history). The HUD shows **momentary** loudness (400 ms window) as the live readout because it is cheap and responsive; the **integrated** number accumulates since the session/meter reset. Both come from the same `LoudnessMeter`. Short-term (3 s) is **not** shown in v1 (no third window) — stated so reviewers don't expect it.
- **AI-confidence is a derived heuristic, not a model output.** DeepFilterNet3 does not emit a "confidence". We derive an **activity** signal = average per-bin gain reduction the blend applied this hop (`1 − wetMag/dryMag`, clamped 0…1, energy-weighted), smoothed. High value = "AI is working hard" (lots of noise being removed). This is computed inside the existing blend loop in `DeepFilterNetDSP.processHop`, where `wetMag`/`dryMag` are already needed for the attenuation floor — near-zero extra cost. It is a UX hint, labeled as such; it is **not** a quality guarantee.

### Current code facts (verified against the repo)
- **Telemetry today:** `AudioModel.inputLevel: Float` (`Sources/Core/AudioModel.swift:24`) is the only meter. It is computed as a strided RMS in `captureOutput(...)` (lines ~673–687) and pushed with `DispatchQueue.main.async { self.inputLevel = rms }` **per capture callback**. There is **no** output-side meter, no peak, no clip, no latency readout.
- **Render callback** (`AudioModel.init`, the `AVAudioSourceNode` closure, lines ~153–193): reads `latencyTarget = 2400` samples (a hardcoded local, line ~167), pulls from `ringBuffer`, applies gain via `vDSP_vsmul`, then `if isAIEnabled { dsp.process(...); chain.process(...) }`. This is the render thread — **allocation-free, no locks**.
- **Added latency** is deterministic: the source-node `latencyTarget` (2400 / 48000 = 50 ms) plus the DSP's STFT hop latency (`frameSize 960` analysis / `hopSize 480`, i.e. one frame ≈ 20 ms) plus the AVAudioEngine I/O buffer. v1 reports the **known fixed component** (ring-buffer target + STFT frame) as "added latency", computed on main from constants — no per-sample measurement.
- **Lock-free scalar pattern** is already blessed: `DeepFilterNetDSP.outputGain` / `suppressionStrength` / `attenuationLimitDb` are plain `public var Float`, written from main, read on the render thread (`AGENTS.md` → "Presets & intensity knobs"; `critical-patterns.md` → "Suppression knobs are lock-free scalars"). Telemetry scalars are the **reverse direction** (render→main) but the same atomicity argument holds on arm64.
- **The blend loop** (`DeepFilterNetDSP.processHop`, lines ~498–509) iterates 481 bins, reading `wetR/wetI` (enhanced) and `rawSpecScratch` (dry) and calling `resolveOutputBin`. `resolveOutputBin` already computes `dryMag`/`wetMag` when `minGain > 0`. The AI-activity accumulator hooks in here.
- **`VoiceChain`** (`Sources/Core/AudioProcessing/VoiceChain.swift`) runs `hp → lowShelf → highShelf → presence → deEsser → comp → limiter` per sample (the Broadcast Voice stages already landed). `configure(_:)` recomputes coefficients on **main**; `process(_:count:)` runs on the **render thread**, allocation-free. The **limiter is last** and is the final ceiling guard. Loudness normalization adds a scalar make-up gain **before** the limiter.
- **`Biquad`** (`Sources/Core/AudioProcessing/Biquad.swift`) is a TDF-II RBJ biquad with `setBypass / setHighPass / setLowShelf / setHighShelf / setPeaking`, a `dcGain` test helper, and `process`. BS.1770 K-weighting needs a **high-shelf** (stage 1) and a **high-pass** (stage 2) — both already exist; no new `Biquad` factory is required.
- **`Limiter`** (`Sources/Core/AudioProcessing/Dynamics.swift`) is `configure(ceilingDb:releaseMs:sampleRate:)` + per-sample `process` with a hard clamp. The normalization ceiling reuses this — we do **not** write a second limiter.
- **Persistence** uses the `mv.*` namespace via the `PrefKey` enum (`AudioModel.swift:114`), `persistSettings()` (~263), `loadSettings()` (~272), guarded by `isApplyingPreset`. New keys: `mv.loudnessNorm` (Bool) + `mv.loudnessTarget` (Float).
- **Tests** live in `Tests/NoNoiseMacTests/` (`@testable import Core`), run headless with `swift test`. Style references: `VoiceChainTests.swift`, `NoNoiseMacDSPTests.swift` (pure static-helper tests), `BroadcastVoiceTests.swift`.
- **UI:** `ContentView.swift` has `statusCard` (which already hosts `MeterView(level: audioModel.inputLevel)`), the shared `MeterView`, and the `nnCard()` modifier. `SettingsView.swift` → `GeneralSettingsView` has `suppressionCard` / `gainCard` and the `sliderRow(...)` / `sectionHeader(...)` helpers.

### Design decisions
- **One telemetry value type, snapshotted once per UI tick.** `AudioTelemetry` is a small struct of scalars living on `AudioModel` (the engine owns the truth). The render/DSP threads write its fields directly; a ~25 Hz timer reads them and assigns the `@Published` mirror properties. Rationale: a single source, a single main-thread touch-point, zero locks.
- **`LoudnessMeter` is the single source of loudness math** (mirroring how `resolveOutputBin`/`minGain` own the blend math and `Biquad` owns filter math). It owns K-weighting, momentary + integrated computation, gating, and sample-peak. It is `Sendable`-friendly value semantics and 100% unit-tested against known BS.1770 reference values (e.g. a −23 LUFS / −40 LUFS calibration tone).
- **Loudness normalization is a gentle scalar auto-gain toward target, computed on main, applied as a lock-free scalar in `VoiceChain` before the limiter.** The meter (running on the DSP/render side) reports integrated/momentary loudness; the main-thread timer computes a target gain (`target − measured`, slew-limited to avoid pumping, clamped to a sane range e.g. ±12 dB) and writes a `loudnessGain` scalar that `VoiceChain.process` multiplies in. The limiter (−3 dB-labeled ceiling) catches any resulting peak. No new render-thread allocation; no per-sample gain solving.
- **Normalization is OFF by default.** Default behavior is byte-for-byte unchanged (gain = 1.0, meter purely passive/observational). Persisted under `mv.loudnessNorm` / `mv.loudnessTarget` (default target −14 LUFS).
- **Tuning values are documented starting points**, tunable after listening (same convention as the presets and Broadcast Voice).

### Telemetry fields (the whole HUD in one table)

| Field | Type | Written by | Meaning |
|---|---|---|---|
| `inputLevel` | `Float` | render callback (pre-DSP RMS) | mic level 0…~1 (existing semantics, moved to telemetry) |
| `outputLevel` | `Float` | render callback (post-chain RMS) | cleaned/processed output level |
| `samplePeak` | `Float` | render callback (post-chain max\|x\|) | peak magnitude this window |
| `clipCount` | `Int32` | render callback (count ≥ clip threshold) | monotonic clip counter → UI shows a clip flag |
| `aiActivity` | `Float` | `DeepFilterNetDSP.processHop` blend loop | smoothed avg gain reduction 0…1 ("AI working hard") |
| `momentaryLUFS` | `Float` | `LoudnessMeter` (via DSP side) | live 400 ms loudness (−∞…0) |
| `integratedLUFS` | `Float` | `LoudnessMeter` (via DSP side) | gated integrated loudness since reset |
| `addedLatencyMs` | `Float` | main (from constants) | fixed pipeline latency readout |

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch** (repo is on `main` with unrelated working-tree changes — do NOT stage those)

```bash
# Run from the package root (the directory that contains Package.swift)
git checkout -b feat/metering-and-loudness
```

Expected: `Switched to a new branch 'feat/metering-and-loudness'`. Throughout this plan, `git add` **only the specific files named in each task** — never `git add -A`/`.`.

---

## Task 1: `LoudnessMeter` — BS.1770 K-weighting + momentary loudness — TDD

The pure loudness value type. Start with K-weighting and the momentary (400 ms) measurement, validated against a known calibration tone.

**Files:**
- Create: `Sources/Core/AudioProcessing/LoudnessMeter.swift`
- Create: `Tests/NoNoiseMacTests/LoudnessMeterTests.swift`

- [ ] **Step 1: Write the failing tests** — create `Tests/NoNoiseMacTests/LoudnessMeterTests.swift`

```swift
import XCTest
@testable import Core

final class LoudnessMeterTests: XCTestCase {

    /// A fresh meter reports silence (the −∞ sentinel) before any audio.
    func testFreshMeterIsSilent() {
        let m = LoudnessMeter(sampleRate: 48000)
        XCTAssertEqual(m.momentaryLUFS, LoudnessMeter.silenceLUFS, accuracy: 1e-3)
        XCTAssertEqual(m.integratedLUFS, LoudnessMeter.silenceLUFS, accuracy: 1e-3)
    }

    /// BS.1770 calibration: a 1 kHz sine at −20 dBFS reads ≈ −23 LUFS mono
    /// (the standard −3 LU mono offset). Tolerance is generous — K-weighting at
    /// 1 kHz is near 0 dB and the standard's reference tone is well-defined.
    func testKWeighted1kSineReadsCalibratedLUFS() {
        var m = LoudnessMeter(sampleRate: 48000)
        let amp: Float = powf(10, -20.0 / 20.0)          // −20 dBFS peak
        // Feed > 400 ms so the momentary window is full.
        for i in 0..<24000 {
            m.process(amp * sinf(2 * Float.pi * 1000 * Float(i) / 48000))
        }
        XCTAssertEqual(m.momentaryLUFS, -23.0, accuracy: 1.0,
                       "−20 dBFS 1 kHz sine must read ≈ −23 LUFS (BS.1770 mono)")
    }

    /// Louder in ⇒ higher (less negative) LUFS — monotonic.
    func testLouderInputReadsHigherLUFS() {
        func measure(_ dbfs: Float) -> Float {
            var m = LoudnessMeter(sampleRate: 48000)
            let amp = powf(10, dbfs / 20.0)
            for i in 0..<24000 { m.process(amp * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) }
            return m.momentaryLUFS
        }
        XCTAssertGreaterThan(measure(-12), measure(-20))
        XCTAssertGreaterThan(measure(-20), measure(-30))
    }

    /// Sample-peak tracks the true max magnitude fed since reset.
    func testSamplePeakTracksMaxMagnitude() {
        var m = LoudnessMeter(sampleRate: 48000)
        for x in [Float(0.1), -0.4, 0.9, -0.2] { m.process(x) }
        XCTAssertEqual(m.samplePeak, 0.9, accuracy: 1e-6)
    }

    /// reset() returns the meter to the silent/no-peak state.
    func testResetClearsState() {
        var m = LoudnessMeter(sampleRate: 48000)
        for i in 0..<24000 { m.process(0.5 * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) }
        m.reset()
        XCTAssertEqual(m.momentaryLUFS, LoudnessMeter.silenceLUFS, accuracy: 1e-3)
        XCTAssertEqual(m.samplePeak, 0, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LoudnessMeterTests`
Expected: compile error — `cannot find 'LoudnessMeter' in scope`.

- [ ] **Step 3: Implement `LoudnessMeter` (K-weighting + momentary + sample-peak)** — create `Sources/Core/AudioProcessing/LoudnessMeter.swift`

```swift
import Foundation

/// ITU-R BS.1770 (K-weighted) loudness meter — a pure, allocation-free value
/// type. Stage 1 = high-shelf "head" filter; stage 2 = high-pass; then mean-square
/// over a sliding momentary window (400 ms). Mono measurement applies the standard
/// −0.691 dB calibration offset. Integrated (gated) loudness is added in Task 2.
///
/// Sample-peak is tracked alongside (NOT certified true-peak — see CONCEPTS.md;
/// oversampled dBTP is deferred for the Apple-Silicon perf mandate).
public struct LoudnessMeter {
    /// Sentinel "silence" value (well below the BS.1770 absolute gate of −70 LUFS).
    public static let silenceLUFS: Float = -120

    private let sampleRate: Float
    private var shelf = Biquad()       // K-weighting stage 1 (high-shelf)
    private var hp = Biquad()          // K-weighting stage 2 (high-pass)

    // Momentary window: sum of K-weighted mean-square over the last ~400 ms.
    private var momentaryRing: [Float]
    private var momentaryHead = 0
    private var momentaryFilled = 0
    private var momentarySum: Float = 0

    private(set) public var samplePeak: Float = 0

    public init(sampleRate: Float = 48000) {
        self.sampleRate = sampleRate
        // BS.1770 K-weighting coefficients are defined at 48 kHz. We approximate
        // with RBJ primitives: a +4 dB high-shelf near 1.5 kHz then an ~38 Hz
        // high-pass. (Exact biquad coefficients can be substituted later without
        // changing the API; the calibration test bounds the error.)
        shelf.setHighShelf(freq: 1500, gainDb: 4, sampleRate: sampleRate)
        hp.setHighPass(freq: 38, sampleRate: sampleRate, q: 0.5)
        let windowLen = max(1, Int(0.4 * sampleRate))   // 400 ms momentary window
        momentaryRing = [Float](repeating: 0, count: windowLen)
    }

    public mutating func reset() {
        shelf.reset(); hp.reset()
        for i in 0..<momentaryRing.count { momentaryRing[i] = 0 }
        momentaryHead = 0; momentaryFilled = 0; momentarySum = 0
        samplePeak = 0
    }

    /// Feed one sample. Updates the K-weighted momentary mean-square ring and the
    /// sample-peak. Allocation-free.
    @inline(__always)
    public mutating func process(_ x: Float) {
        let mag = abs(x)
        if mag > samplePeak { samplePeak = mag }
        let k = hp.process(shelf.process(x))     // K-weighted sample
        let sq = k * k
        // Sliding-window sum: subtract the slot we overwrite, add the new square.
        momentarySum += sq - momentaryRing[momentaryHead]
        momentaryRing[momentaryHead] = sq
        momentaryHead += 1
        if momentaryHead == momentaryRing.count { momentaryHead = 0 }
        if momentaryFilled < momentaryRing.count { momentaryFilled += 1 }
    }

    /// Loudness of the current momentary (400 ms) window, in LUFS. Returns the
    /// silence sentinel until the window has any energy.
    public var momentaryLUFS: Float {
        Self.loudness(meanSquare: momentaryFilled > 0 ? momentarySum / Float(momentaryFilled) : 0)
    }

    /// Integrated (gated) loudness — implemented in Task 2. Until then it mirrors
    /// momentary so the property exists for the telemetry wiring.
    public var integratedLUFS: Float { momentaryLUFS }

    /// LUFS from a K-weighted mean-square value, with the BS.1770 −0.691 dB offset.
    /// Returns the silence sentinel for non-positive energy.
    static func loudness(meanSquare ms: Float) -> Float {
        guard ms > 0 else { return silenceLUFS }
        return -0.691 + 10 * log10f(ms)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LoudnessMeterTests`
Expected: 5 tests PASS. (If the calibration test misses, adjust the shelf gain/freq within the ±1 LU tolerance — the test bounds the K-weighting approximation; do not loosen the tolerance.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/LoudnessMeter.swift Tests/NoNoiseMacTests/LoudnessMeterTests.swift
git commit -m "feat(dsp): add LoudnessMeter (BS.1770 K-weighting + momentary LUFS + sample-peak)"
```

---

## Task 2: Integrated (gated) LUFS — TDD

Add gated integration to `LoudnessMeter`: per-400 ms-block loudness, absolute −70 LUFS gate, relative −10 LU gate over the running block set. Use a streaming accumulator (no unbounded history).

**Files:**
- Modify: `Sources/Core/AudioProcessing/LoudnessMeter.swift`
- Modify: `Tests/NoNoiseMacTests/LoudnessMeterTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `LoudnessMeterTests`

```swift
    // MARK: - Integrated (gated) loudness

    /// A steady tone yields an integrated value ≈ its momentary value.
    func testIntegratedMatchesSteadyTone() {
        var m = LoudnessMeter(sampleRate: 48000)
        let amp = powf(10, -20.0 / 20.0)
        for i in 0..<96000 { m.process(amp * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) } // 2 s
        XCTAssertEqual(m.integratedLUFS, m.momentaryLUFS, accuracy: 1.0)
        XCTAssertEqual(m.integratedLUFS, -23.0, accuracy: 1.0)
    }

    /// Silence below the absolute −70 LUFS gate does NOT drag the integrated value
    /// down: a loud passage followed by silence still integrates near the loud level.
    func testIntegratedGatesOutSilence() {
        var m = LoudnessMeter(sampleRate: 48000)
        let amp = powf(10, -20.0 / 20.0)
        for i in 0..<96000 { m.process(amp * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) } // 2 s loud
        for _ in 0..<96000 { m.process(0) }                                                  // 2 s silence
        XCTAssertEqual(m.integratedLUFS, -23.0, accuracy: 1.5,
                       "gated integration must ignore the silent gap")
    }

    /// Integrated loudness ignores blocks below the relative gate (quiet vs loud).
    func testIntegratedIsGatedNotPlainAverage() {
        var m = LoudnessMeter(sampleRate: 48000)
        let loud = powf(10, -14.0 / 20.0)
        let quiet = powf(10, -50.0 / 20.0)  // > 10 LU below loud → gated out
        for i in 0..<96000 { m.process(loud  * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) }
        for i in 0..<96000 { m.process(quiet * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) }
        let plainAverageWouldBe: Float = -20  // rough midpoint if NOT gated
        XCTAssertGreaterThan(m.integratedLUFS, plainAverageWouldBe,
                             "relative gate must drop the quiet blocks, keeping the level near the loud passage")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LoudnessMeterTests`
Expected: the three new tests FAIL (integrated currently just mirrors momentary — `testIntegratedGatesOutSilence` and `testIntegratedIsGatedNotPlainAverage` fail).

- [ ] **Step 3: Add gated integration** to `LoudnessMeter`

Add block-accumulation state (alongside the momentary state):

```swift
    // Integrated (gated) state — per 400 ms block. We keep only running sums so
    // there is no unbounded history (one streaming accumulator, not a sample log).
    private var blockLen = 0
    private var blockCount = 0
    private var blockMeanSquareSum: Float = 0   // mean-square accumulated in the current block
    private var blockSamples = 0
    // Absolute-gate-passing blocks: count + Σ mean-square (for the relative gate's threshold)
    private var absGatedCount = 0
    private var absGatedMSSum: Float = 0
    // Relative-gate-passing blocks: the integrated answer comes from these.
    private struct GatedAccumulator { var count = 0; var msSum: Float = 0 }
    private var blockMSLog: [Float] = []   // bounded? see note below
```

> **Implementation note for the executor:** the relative gate needs to re-test every absolute-gated block against a threshold derived from the mean of all absolute-gated blocks. The simplest correct implementation keeps the per-block mean-square values for absolute-gated blocks in `blockMSLog`. To honor "no unbounded history", cap `blockMSLog` to a rolling window of the last N blocks (e.g. N = 7500 ≈ 50 min of program) — long past any realtime session, bounded memory. Document this cap in the file header and `CONCEPTS.md`. If the executor prefers an exact-but-bounded approach, a two-pass-free relative gate can be approximated by recomputing the relative threshold from `absGatedMSSum/absGatedCount` and applying it to the logged blocks; either is acceptable as long as the three tests pass.

Implement block finalization inside `process(_:)` (after the momentary update): accumulate `blockMeanSquareSum += sq; blockSamples += 1`; when `blockSamples == blockLen` (set `blockLen = Int(0.4 * sampleRate)` in `init`), finalize the block (compute its mean-square, push to the absolute-gate accumulators / log if its loudness > −70 LUFS), reset the block accumulators, and `blockCount += 1`. Compute `integratedLUFS` from the relative-gated set:

```swift
    public var integratedLUFS: Float {
        guard absGatedCount > 0 else { return Self.silenceLUFS }
        // Relative gate: −10 LU below the mean loudness of absolute-gated blocks.
        let absMeanMS = absGatedMSSum / Float(absGatedCount)
        let relThresholdMS = absMeanMS * powf(10, -10.0 / 10.0)   // −10 LU in the power domain
        var acc = GatedAccumulator()
        for ms in blockMSLog where ms >= relThresholdMS {
            acc.count += 1; acc.msSum += ms
        }
        guard acc.count > 0 else { return Self.loudness(meanSquare: absMeanMS) }
        return Self.loudness(meanSquare: acc.msSum / Float(acc.count))
    }
```

Update `reset()` and `init()` to clear/initialize the new block state. (Remove the temporary `integratedLUFS { momentaryLUFS }` from Task 1.)

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter LoudnessMeterTests`
Expected: all 8 `LoudnessMeterTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/LoudnessMeter.swift Tests/NoNoiseMacTests/LoudnessMeterTests.swift
git commit -m "feat(dsp): add gated integrated LUFS (BS.1770 absolute + relative gating)"
```

---

## Task 3: Loudness normalization gain — pure helper — TDD

The math that maps measured loudness + target → a slew-limited make-up gain (toward target, no pumping, clamped). Pure static helper so it is testable without `AudioModel`/CoreAudio (mirrors `minGain` / `resolveOutputBin`).

**Files:**
- Modify: `Sources/Core/AudioProcessing/LoudnessMeter.swift` (add static helper)
- Modify: `Tests/NoNoiseMacTests/LoudnessMeterTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `LoudnessMeterTests`

```swift
    // MARK: - Normalization gain

    /// Quiet program (below target) ⇒ make-up gain > 1 (boost toward target).
    func testNormGainBoostsQuietProgram() {
        let g = LoudnessMeter.normalizationGain(measuredLUFS: -23, targetLUFS: -14,
                                                currentGain: 1, maxDb: 12, slewDb: 12)
        XCTAssertGreaterThan(g, 1.0)
    }

    /// Loud program (above target) ⇒ gain < 1 (pull down toward target).
    func testNormGainAttenuatesLoudProgram() {
        let g = LoudnessMeter.normalizationGain(measuredLUFS: -8, targetLUFS: -14,
                                                currentGain: 1, maxDb: 12, slewDb: 12)
        XCTAssertLessThan(g, 1.0)
    }

    /// The make-up gain is clamped to ±maxDb so a near-silent meter can't blow up.
    func testNormGainIsClampedToMaxDb() {
        let g = LoudnessMeter.normalizationGain(measuredLUFS: -90, targetLUFS: -14,
                                                currentGain: 1, maxDb: 12, slewDb: 100)
        XCTAssertLessThanOrEqual(g, powf(10, 12.0 / 20.0) + 1e-4, "gain capped at +12 dB")
    }

    /// Silence (below the absolute gate) holds the current gain — no gain-pumping on gaps.
    func testNormGainHoldsOnSilence() {
        let g = LoudnessMeter.normalizationGain(measuredLUFS: LoudnessMeter.silenceLUFS,
                                                targetLUFS: -14, currentGain: 1.7, maxDb: 12, slewDb: 12)
        XCTAssertEqual(g, 1.7, accuracy: 1e-6, "no measurement → hold gain (no pumping)")
    }

    /// Per-update change is slew-limited (can't jump the full distance in one tick).
    func testNormGainIsSlewLimited() {
        // Target needs +9 dB but slew caps the per-tick move at +3 dB from unity.
        let g = LoudnessMeter.normalizationGain(measuredLUFS: -23, targetLUFS: -14,
                                                currentGain: 1, maxDb: 12, slewDb: 3)
        XCTAssertLessThanOrEqual(g, powf(10, 3.0 / 20.0) + 1e-4, "slew caps the step")
        XCTAssertGreaterThan(g, 1.0)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LoudnessMeterTests`
Expected: compile error — `type 'LoudnessMeter' has no member 'normalizationGain'`.

- [ ] **Step 3: Add the static helper** to `LoudnessMeter`

```swift
    /// Slew-limited make-up gain toward a loudness target. Returns a LINEAR gain
    /// to multiply the signal by. Holds `currentGain` when there is no measurement
    /// (silence below the absolute gate) so silent gaps never cause pumping.
    /// `maxDb` clamps the absolute make-up; `slewDb` caps the per-update change.
    static func normalizationGain(measuredLUFS: Float, targetLUFS: Float,
                                  currentGain: Float, maxDb: Float, slewDb: Float) -> Float {
        guard measuredLUFS > silenceLUFS else { return currentGain }   // no data → hold
        let neededDb = targetLUFS - measuredLUFS                       // + = boost, − = cut
        let clampedTargetDb = min(max(neededDb, -abs(maxDb)), abs(maxDb))
        let targetGain = powf(10, clampedTargetDb / 20)
        // Slew toward targetGain in the dB domain so steps are perceptually even.
        let currentDb = 20 * log10f(max(currentGain, 1e-6))
        let targetGainDb = 20 * log10f(max(targetGain, 1e-6))
        let stepDb = min(max(targetGainDb - currentDb, -abs(slewDb)), abs(slewDb))
        return powf(10, (currentDb + stepDb) / 20)
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter LoudnessMeterTests`
Expected: all `LoudnessMeterTests` PASS (8 + 5 = 13).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/LoudnessMeter.swift Tests/NoNoiseMacTests/LoudnessMeterTests.swift
git commit -m "feat(dsp): add slew-limited loudness normalization gain helper"
```

---

## Task 4: AI-activity signal from the DSP blend — TDD

Expose a smoothed "AI working hard" scalar derived from the per-bin gain reduction the blend already computes. The math is a pure static helper; the accumulation hooks into `processHop`.

**Files:**
- Modify: `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift` (static helper + accumulator + lock-free scalar)
- Modify: `Tests/NoNoiseMacTests/NoNoiseMacDSPTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `NoNoiseMacDSPTests`

```swift
    // MARK: - AI activity (suppression confidence)

    /// No reduction (wet == dry magnitude) ⇒ activity 0 ("AI doing nothing").
    func testAIActivityZeroWhenWetEqualsDry() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 0.5, wetMag: 0.5)
        XCTAssertEqual(a, 0, accuracy: 1e-6)
    }

    /// Full suppression (wet ~0 against real dry) ⇒ activity ~1 ("AI working hard").
    func testAIActivityOneWhenFullySuppressed() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 0.5, wetMag: 0.0)
        XCTAssertEqual(a, 1, accuracy: 1e-6)
    }

    /// Half suppression ⇒ ~0.5.
    func testAIActivityHalfWhenHalfSuppressed() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 1.0, wetMag: 0.5)
        XCTAssertEqual(a, 0.5, accuracy: 1e-6)
    }

    /// Silence (dry ~0) ⇒ activity 0 (no division blow-up; nothing to suppress).
    func testAIActivityZeroOnSilentDry() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 0.0, wetMag: 0.0)
        XCTAssertEqual(a, 0, accuracy: 1e-6)
    }

    /// Wet louder than dry (the model added energy) clamps to 0, never negative.
    func testAIActivityClampsWhenWetExceedsDry() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 0.2, wetMag: 0.5)
        XCTAssertEqual(a, 0, accuracy: 1e-6)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter NoNoiseMacDSPTests`
Expected: compile error — `type 'DeepFilterNetDSP' has no member 'binActivity'`.

- [ ] **Step 3: Add the helper + scalar + accumulation** to `DeepFilterNetDSP`

Add the pure helper (place it next to `minGain` / `resolveOutputBin`):

```swift
    /// Per-bin suppression "activity": how much the enhanced (wet) magnitude was
    /// reduced relative to the dry magnitude, clamped to [0, 1]. 0 = no reduction
    /// (or silence / wet ≥ dry), 1 = fully suppressed. Pure → unit-testable.
    static func binActivity(dryMag: Float, wetMag: Float) -> Float {
        guard dryMag > 1e-9 else { return 0 }
        let reduction = 1 - wetMag / dryMag
        return min(max(reduction, 0), 1)
    }
```

Add a lock-free telemetry scalar (mirroring `outputGain` — written on the DSP/render side, read on main):

```swift
    /// Smoothed "AI working hard" signal in [0, 1] — the energy-weighted average
    /// per-bin suppression applied last hop, one-pole smoothed. Written on the DSP
    /// thread, read from main (lock-free scalar; atomic on arm64 — same pattern as
    /// `outputGain`). UX hint only; NOT a model-quality guarantee.
    public var aiActivity: Float = 0
```

In `processHop`, inside the existing blend loop (lines ~498–509), accumulate energy-weighted reduction using the dry/wet magnitudes (compute them once per bin — `dryMag` is already available where `minGain > 0`; compute both unconditionally here since the loop already reads `wetR/wetI` and `rawSpecScratch`). After the loop, fold into the smoothed scalar:

```swift
        // (declare before the loop)
        var actWeightSum: Float = 0     // Σ dryMag (energy weight)
        var actValueSum: Float = 0      // Σ dryMag · binActivity
        // (inside the loop, after computing outR/outI for bin i)
        let dMag = sqrtf(rawSpecScratch[i*2] * rawSpecScratch[i*2] + rawSpecScratch[i*2+1] * rawSpecScratch[i*2+1])
        let wMag = sqrtf(wetR * wetR + wetI * wetI)
        let act = Self.binActivity(dryMag: dMag, wetMag: wMag)
        actWeightSum += dMag
        actValueSum += dMag * act
        // (after the loop)
        let hopActivity = actWeightSum > 1e-9 ? actValueSum / actWeightSum : 0
        let smooth: Float = 0.85   // one-pole smoothing across hops
        aiActivity = smooth * aiActivity + (1 - smooth) * hopActivity
```

> **Perf note for the executor:** `binActivity` and the two `sqrtf`s run 481×/hop. This is scalar arithmetic on data already in registers/L1 from the blend; it does NOT allocate. The smoothing fold is O(1). Keep it inside the `if isModelLoaded` block (only meaningful when the model ran). When the model is loading / AI off, leave `aiActivity` decaying toward 0 (optional: in the `else` branch set `aiActivity *= smooth`).

- [ ] **Step 4: Run to verify pass + full suite**

Run: `swift test`
Expected: the 5 new activity tests PASS; all existing tests still PASS (no behavior change to the blend output — `aiActivity` is read-only telemetry).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift Tests/NoNoiseMacTests/NoNoiseMacDSPTests.swift
git commit -m "feat(dsp): derive AI-activity telemetry from per-bin suppression"
```

---

## Task 5: Loudness normalization gain in `VoiceChain` — TDD

Carry a `loudnessGain` lock-free scalar on `VoiceChain`, applied as a pre-limiter make-up multiply. Default 1.0 (no-op). The limiter (already last) is the ceiling guard.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift` (scalar + apply before limiter)
- Modify: `Tests/NoNoiseMacTests/VoiceChainTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `VoiceChainTests`

```swift
    // MARK: - Loudness normalization gain

    /// Default loudnessGain (1.0) is a no-op: disabled chain still passes through.
    func testLoudnessGainDefaultIsNoOp() {
        let chain = VoiceChain()
        chain.configure(.disabled)               // polish off, clarity off
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "default loudnessGain must not alter samples")
    }

    /// A loudnessGain > 1 boosts the signal (still within the limiter ceiling).
    func testLoudnessGainBoostsWhenActive() {
        let chain = VoiceChain()
        chain.configure(VoicePreset.podcast.voiceChain)  // chain active (polish on)
        chain.setLoudnessGain(2.0)
        var loud = [Float](repeating: 0.1, count: 4800)
        var quiet = [Float](repeating: 0.1, count: 4800)
        chain.setLoudnessGain(1.0)
        let chain2 = VoiceChain(); chain2.configure(VoicePreset.podcast.voiceChain)
        loud.withUnsafeMutableBufferPointer  { chain.process($0.baseAddress!, count: $0.count) }
        quiet.withUnsafeMutableBufferPointer { chain2.process($0.baseAddress!, count: $0.count) }
        // The 2.0-gain chain must end louder than the 1.0-gain chain (both under ceiling).
        let rmsLoud  = sqrtf(loud.reduce(0)  { $0 + $1*$1 } / Float(loud.count))
        let rmsQuiet = sqrtf(quiet.reduce(0) { $0 + $1*$1 } / Float(quiet.count))
        XCTAssertGreaterThan(rmsLoud, rmsQuiet)
    }

    /// Even with a large loudnessGain, the limiter still caps output at the ceiling.
    func testLoudnessGainStillRespectsLimiterCeiling() {
        let chain = VoiceChain()
        chain.configure(VoicePreset.podcast.voiceChain)
        chain.setLoudnessGain(8.0)               // extreme boost
        var buf = [Float](repeating: 0.5, count: 4800)
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        let ceiling = powf(10, -1.0 / 20.0)      // podcast limiter ceiling
        XCTAssertTrue(buf.allSatisfy { abs($0) <= ceiling + 1e-3 }, "limiter must still hold the ceiling")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter VoiceChainTests`
Expected: compile error — `value of type 'VoiceChain' has no member 'setLoudnessGain'`.

- [ ] **Step 3: Add the scalar + apply** in `VoiceChain`

Add the stored scalar next to the stages:

```swift
    /// Loudness-normalization make-up gain (linear). Written from main (lock-free
    /// scalar; atomic on arm64), read on the render thread. 1.0 = no-op. Applied
    /// just BEFORE the limiter so the ceiling still bounds the boosted signal.
    private var loudnessGain: Float = 1
```

Add the setter (coefficient-free, so it is safe from main without a full reconfigure):

```swift
    /// Set the loudness make-up gain. Plain scalar store — cheaper than a full
    /// configure; called from the main-thread loudness timer.
    public func setLoudnessGain(_ g: Float) { loudnessGain = g }
```

In `process(_:count:)`, multiply by `loudnessGain` immediately before `limiter.process(x)`:

```swift
            if doPolish { x = comp.process(x) }
            x *= loudnessGain               // loudness normalization make-up (pre-limiter)
            x = limiter.process(x)
            buffer[i] = x
```

> **Important:** the chain must run when `loudnessGain != 1` even if polish + clarity are off, OR loudness normalization must be applied only while the chain is already active. **Decision:** apply only while active (limiter must run to guard the boost). When normalization is enabled but the chain would otherwise be inactive, `AudioModel` activates the limiter by treating normalization as an "active" reason (see Task 6) — but to keep this task isolated and the regression green, this task ONLY adds the scalar + multiply inside the existing `guard active` path. The "activate for loudness" wiring is Task 6.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all tests PASS (new loudness tests + existing `VoiceChainTests` + `BroadcastVoiceTests` regression — `loudnessGain` defaults to 1.0 so every existing test is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift Tests/NoNoiseMacTests/VoiceChainTests.swift
git commit -m "feat(dsp): apply pre-limiter loudness make-up gain in VoiceChain"
```

---

## Task 6: Telemetry + loudness wiring in `AudioModel`

Add the telemetry scalars, the `LoudnessMeter`, the ~25 Hz UI snapshot timer, the normalization controls, and persistence. **No XCTest:** `AudioModel` depends on CoreAudio/AVCapture and is not unit-testable in the headless suite. Verification is `swift build` + the green Core suite + the manual smoke test.

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

- [ ] **Step 1: Add `@Published` HUD properties** (after `inputLevel`, line ~24)

```swift
    /// Live HUD telemetry, refreshed ~25 Hz from lock-free scalars (not per buffer).
    @Published public var outputLevel: Float = 0.0
    @Published public var outputPeak: Float = 0.0
    @Published public var isClipping: Bool = false
    @Published public var aiActivity: Float = 0.0        // "AI working hard" 0…1
    @Published public var momentaryLUFS: Float = LoudnessMeter.silenceLUFS
    @Published public var integratedLUFS: Float = LoudnessMeter.silenceLUFS
    @Published public var addedLatencyMs: Float = 0.0
```

- [ ] **Step 2: Add normalization controls + `PrefKey`s**

Add to `PrefKey` (line ~114):

```swift
        static let loudnessNorm = "mv.loudnessNorm"
        static let loudnessTarget = "mv.loudnessTarget"
```

Add `@Published` controls (after `voicePolishEnabled`, ~line 110):

```swift
    /// Loudness normalization (gentle auto-gain toward target). OFF by default —
    /// default behavior is byte-for-byte unchanged. Guarded like the other knobs.
    @Published public var loudnessNormEnabled: Bool = false {
        didSet {
            guard !isApplyingPreset else { return }
            if !loudnessNormEnabled { voiceChain.setLoudnessGain(1.0) }  // reset to unity when off
            applyVoiceChain()                                            // (re)activate chain if needed
            persistSettings()
        }
    }
    /// Target integrated loudness in LUFS (e.g. −14 YouTube/Spotify, −16 Apple Podcasts).
    @Published public var loudnessTargetLUFS: Float = -14 {
        didSet { guard !isApplyingPreset else { return }; persistSettings() }
    }
```

- [ ] **Step 3: Add the lock-free telemetry scalars + the `LoudnessMeter`** (near the processing modules, ~line 143)

```swift
    private let loudnessMeter = LoudnessMeter()
    // Render-thread → main lock-free scalars (atomic on arm64). Written in the
    // render callback / read by the UI timer. NOT @Published (no per-write churn).
    private var tInputLevel: Float = 0
    private var tOutputLevel: Float = 0
    private var tOutputPeak: Float = 0
    private var tClipCount: Int32 = 0
    private var currentLoudnessGain: Float = 1
```

> **Note:** `LoudnessMeter` is a struct (value type). To mutate it from the render closure and the timer, store it as a class-held property and mutate via `withUnsafeMutablePointer`-free direct access, OR wrap loudness measurement on the DSP-output samples in the render callback (single-threaded with the render thread). Keep all `loudnessMeter` mutation on the render thread; the timer only **reads** `momentaryLUFS` / `integratedLUFS` / `samplePeak` (pure getters over scalar state — safe). If the executor finds value-type capture awkward in the closure, promote the needed accumulators following the same pattern as the other scalars; do NOT introduce a lock.

- [ ] **Step 4: Write telemetry in the render callback** (the `AVAudioSourceNode` closure, after `chain.process(...)`, ~line 189)

Compute post-processing output level/peak/clip over the in-place `data` buffer (scalar loop, no allocation), feed each output sample to `loudnessMeter.process(_:)`, and store the input-level RMS (replacing the per-callback `inputLevel` main-thread hop in `captureOutput` — see Step 6). Example shape (allocation-free):

```swift
                // Telemetry (render thread → lock-free scalars). No allocation.
                var sumSq: Float = 0, peak: Float = 0
                let clipThreshold: Float = 0.999
                var clips: Int32 = 0
                for i in 0..<count {
                    let s = data[i]
                    let m = abs(s)
                    sumSq += s * s
                    if m > peak { peak = m }
                    if m >= clipThreshold { clips += 1 }
                    self.loudnessMeter.process(s)   // K-weighted loudness + sample-peak
                }
                self.tOutputLevel = sqrtf(sumSq / Float(max(count, 1)))
                self.tOutputPeak = peak
                if clips > 0 { self.tClipCount &+= clips }

                // Loudness make-up (read the gain computed on main; apply via chain).
                // (chain already multiplied loudnessGain; nothing per-sample here.)
```

> The DSP-side `aiActivity` is read from `dspEngine.aiActivity` by the timer (Step 5), not here.

- [ ] **Step 5: Add the ~25 Hz UI snapshot timer**

Add a `Timer` (40 ms ≈ 25 Hz) started in `init()` (after `loadSettings()`), invalidated in `deinit`. On each tick (main thread):

```swift
    private var meterTimer: Timer?

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.outputLevel = self.tOutputLevel
            self.outputPeak = self.tOutputPeak
            self.isClipping = self.tClipCount > 0
            self.tClipCount = 0                                  // clear after surfacing (latched ~per tick)
            self.aiActivity = self.dspEngine.aiActivity
            self.momentaryLUFS = self.loudnessMeter.momentaryLUFS
            self.integratedLUFS = self.loudnessMeter.integratedLUFS
            // Loudness normalization: compute a slew-limited make-up gain on main,
            // push it to the chain as a lock-free scalar (only when enabled + active).
            if self.loudnessNormEnabled {
                let g = LoudnessMeter.normalizationGain(
                    measuredLUFS: self.integratedLUFS, targetLUFS: self.loudnessTargetLUFS,
                    currentGain: self.currentLoudnessGain, maxDb: 12, slewDb: 1)  // ~1 dB/tick → smooth
                self.currentLoudnessGain = g
                self.voiceChain.setLoudnessGain(g)
            }
        }
    }
```

> **Perf:** `slewDb: 1` per 40 ms tick = max ~25 dB/s — fast enough to track, slow enough to never pump. `addedLatencyMs` is set once (Step 7), not per tick.

- [ ] **Step 6: Replace the per-callback `inputLevel` hop**

In `captureOutput(...)` (lines ~673–687), the existing block computes a strided RMS and does `DispatchQueue.main.async { self.inputLevel = rms }` **every callback**. Replace the async hop with a scalar store `self.tInputLevel = rms` (lock-free), and have the timer assign `self.inputLevel = self.tInputLevel` in `startMeterTimer`. This removes a per-buffer main-thread dispatch (perf mandate: no needless main-thread churn) while preserving the input meter.

- [ ] **Step 7: Compute `addedLatencyMs` from constants** in `init()` (after engine setup)

```swift
    // Fixed pipeline latency: ring-buffer target (2400 samples) + one STFT frame
    // (960 samples). Reported as the "added latency" readout. Not a per-sample measure.
    addedLatencyMs = Float(2400 + 960) / 48000.0 * 1000.0   // = 70 ms
```

> Extract `latencyTarget`/`frameSize` to named constants if the executor prefers; do not change the render behavior. If `latencyTarget` is later made configurable, recompute here.

- [ ] **Step 8: Persist + restore** the normalization controls

In `persistSettings()`:

```swift
        d.set(loudnessNormEnabled, forKey: PrefKey.loudnessNorm)
        d.set(loudnessTargetLUFS, forKey: PrefKey.loudnessTarget)
```

In `loadSettings()`, inside the `isApplyingPreset = true … = false` guarded region:

```swift
        loudnessNormEnabled = d.object(forKey: PrefKey.loudnessNorm) as? Bool ?? false
        loudnessTargetLUFS  = d.object(forKey: PrefKey.loudnessTarget) != nil
            ? d.float(forKey: PrefKey.loudnessTarget) : -14
```

- [ ] **Step 9: Wire `loudnessNormEnabled` into chain activation**

`applyVoiceChain()` currently sets `s.enabled = s.enabled && voicePolishEnabled; s.clarity = clarityLevel`. Loudness normalization needs the **limiter** running to guard the boost. The chain is already active when polish or clarity is on. When BOTH are off but normalization is on, the chain would be inactive and the make-up gain would be ignored. Resolve by ensuring the limiter runs: the simplest correct option is to keep `VoiceChain`'s `active` gating as-is and, in `AudioModel`, only apply `loudnessGain` while the chain is active — i.e. document that **loudness normalization requires Voice Polish or Broadcast Voice on** (both are the realistic creator setup), OR add a `normalizeActive` reason to `VoiceChainSettings`/`configure`.

> **Decision (state explicitly, ask if uncertain):** v1 ties normalization activation to the chain being active for another reason is too surprising. Add a `loudnessActive: Bool` to `VoiceChainSettings` (defaulted `false`, backward-compatible memberwise init) and OR it into `active` in `configure` (so the limiter + make-up run on their own). Set `s.loudnessActive = loudnessNormEnabled` in `applyVoiceChain()`. This keeps normalization usable in Meeting mode. **This is a small `VoiceChain` change — if the executor disagrees with adding the field, surface it before coding.**

- [ ] **Step 10: Start/stop the timer**

Call `startMeterTimer()` at the end of `init()`; in `deinit`, `meterTimer?.invalidate()`.

- [ ] **Step 11: Build + regression test**

Run: `swift build && swift test`
Expected: build succeeds; all tests PASS.

- [ ] **Step 12: Commit**

```bash
git add Sources/Core/AudioModel.swift
git commit -m "feat(audio): render-thread telemetry + LUFS meter + loudness normalization wiring"
```

> If Step 9 required the `loudnessActive` field, also `git add Sources/Core/AudioProcessing/VoiceChain.swift Tests/NoNoiseMacTests/VoiceChainTests.swift` with a test that `loudnessActive` alone activates the chain, in a separate commit `feat(dsp): activate VoiceChain for loudness normalization`.

---

## Task 7: Live HUD UI — popover + Settings

Surface the HUD: output meter, clip warning, AI-activity, latency readout (popover), and the full LUFS panel + normalization controls (Settings). **No XCTest** (SwiftUI views) — verify by build + manual.

**Files:**
- Modify: `Sources/App/ContentView.swift`
- Modify: `Sources/App/SettingsView.swift`

- [ ] **Step 1: Extend the popover `statusCard`** (`ContentView.swift`) — add an output meter row + a clip flag beneath the existing input `MeterView`:

```swift
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.caption2).foregroundColor(.secondary)
                MeterView(level: audioModel.inputLevel).frame(height: 6)
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundColor(.secondary)
                MeterView(level: audioModel.outputLevel).frame(height: 6)
                if audioModel.isClipping {
                    Text("CLIP").font(.caption2).fontWeight(.bold).foregroundColor(.red)
                }
            }
```

- [ ] **Step 2: Add a compact `hudCard`** (`ContentView.swift`) after `modeCard` — AI-activity bar + latency + momentary LUFS:

```swift
    private var hudCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardLabel("Live", systemImage: "waveform.path.ecg")
            HStack(spacing: 8) {
                Text("AI").font(.caption2).foregroundColor(.secondary)
                MeterView(level: audioModel.aiActivity / 5).frame(height: 6)  // MeterView scales ×5 internally
            }
            HStack {
                Text(audioModel.momentaryLUFS <= LoudnessMeter.silenceLUFS + 1
                     ? "— LUFS" : String(format: "%.1f LUFS", audioModel.momentaryLUFS))
                    .font(.caption).monospacedDigit().foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f ms latency", audioModel.addedLatencyMs))
                    .font(.caption).monospacedDigit().foregroundColor(.secondary)
            }
        }
        .nnCard()
    }
```

> `MeterView` multiplies `level` by 5 internally (`CGFloat(level) * 5 * width`); `aiActivity` is already 0…1, so divide by 5 to use the full bar without a 5× over-scale. Document this in an inline comment. (If the executor prefers, add a `scaledLevel` view rather than abusing the divide — keep it minimal.)

- [ ] **Step 3: Place `hudCard`** in `ContentView.body`'s `VStack`, after `modeCard`:

```swift
            modeCard
            hudCard
            devicesCard
```

- [ ] **Step 4: Add the loudness panel to Settings** (`SettingsView.swift`) — a new `loudnessCard` in `GeneralSettingsView.body` (after `gainCard`): the integrated LUFS readout, a normalization toggle, and a target picker (−14 / −16 LUFS):

```swift
    private var loudnessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Loudness", systemImage: "speaker.wave.2.circle.fill")
                Spacer()
                Text(audioModel.integratedLUFS <= LoudnessMeter.silenceLUFS + 1
                     ? "— LUFS" : String(format: "%.1f LUFS", audioModel.integratedLUFS))
                    .font(.callout).monospacedDigit().foregroundColor(.secondary)
            }
            Toggle(isOn: $audioModel.loudnessNormEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Normalize Loudness").font(.subheadline)
                    Text("Gently rides gain toward a target level so you’re consistent across calls and recordings.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            Picker("Target", selection: $audioModel.loudnessTargetLUFS) {
                Text("−14 LUFS (YouTube / Spotify)").tag(Float(-14))
                Text("−16 LUFS (Apple Podcasts)").tag(Float(-16))
            }
            .pickerStyle(.menu)
            .disabled(!audioModel.loudnessNormEnabled)
            Text("Peak-safe: output is capped ~3 dB below clipping. Loudness is K-weighted (ITU-R BS.1770); peak is sample-peak, not certified true-peak.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .nnCard()
    }
```

Add `loudnessCard` to the `VStack` after `gainCard`.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/App/ContentView.swift Sources/App/SettingsView.swift
git commit -m "feat(ui): Live HUD (levels/clip/AI/latency) + LUFS loudness panel"
```

---

## Task 8: Documentation (8-Fold Awareness Step 2 + compounding)

Every code change requires a docs pass. Update user docs, domain vocab, the architecture map, and the knowledge base.

**Files:**
- Modify: `README.md`
- Modify: `CONCEPTS.md`
- Modify: `AGENTS.md`
- Modify: `docs/knowledge/timeline1.md`
- Modify: `docs/knowledge/knowledge1.md`

- [ ] **Step 1: `README.md`** — add a feature bullet under "✨ Why NoNoise Mac":

```markdown
- **📊 Live HUD & loudness** — see your input/output levels, a clip warning, an “AI working hard” signal, and added latency at a glance; an ITU-R BS.1770 LUFS meter with optional one-tap loudness normalization (−14 / −16 LUFS) keeps you consistent across calls and recordings.
```

- [ ] **Step 2: `CONCEPTS.md`** — add a "Metering & loudness" section:

```markdown
## Metering & loudness
- **Telemetry** — lock-free scalars written on the render/DSP threads and read by a
  ~25 Hz UI timer (same atomic-scalar pattern as the suppression knobs; no locks).
- **AI activity** — a smoothed 0…1 "AI working hard" signal = energy-weighted average
  per-bin suppression (`1 − wetMag/dryMag`) from the DSP blend. A UX hint, not a model
  quality metric.
- **LUFS (`LoudnessMeter`)** — ITU-R BS.1770 K-weighted loudness. Momentary (400 ms)
  is the live needle; integrated is gated (absolute −70 LUFS + relative −10 LU).
- **Loudness normalization** — optional slew-limited make-up gain toward a target
  (−14 / −16 LUFS), applied pre-limiter in the voice chain; OFF by default.
- **Peak** — v1 tracks **sample-peak** + a clip flag, NOT oversampled true-peak; the
  normalization ceiling is a peak-safe limiter (~−3 dB), not certified dBTP.
```

- [ ] **Step 3: `AGENTS.md`** — add a "Metering & loudness (Tier 2)" section after the "Voice polish chain (Tier 2)" section:

```markdown
## Metering & loudness (Tier 2)
- **Telemetry is lock-free scalars** written render→main (the reverse of the suppression
  knobs, same arm64 atomicity argument). The render callback writes output level/peak/clip;
  `DeepFilterNetDSP.aiActivity` is written in the blend loop; a ~25 Hz `Timer` on `AudioModel`
  snapshots them into `@Published` props. NEVER add locks; NEVER push per-buffer to main
  (the old per-callback `inputLevel` dispatch was replaced by the timer snapshot).
- **`LoudnessMeter` (Core/AudioProcessing)** owns all BS.1770 math (K-weighting biquads,
  momentary + gated-integrated LUFS, sample-peak, and the `normalizationGain` helper) as a
  pure, headless-tested value type — same rule as `Biquad`/`resolveOutputBin`.
- **v1 is sample-peak, not true-peak** (oversampled dBTP deferred for perf). Do not relabel
  the peak as dBTP. Integrated LUFS uses a bounded block log (no unbounded sample history).
- **Loudness normalization** is a main-computed, slew-limited scalar `loudnessGain` applied
  pre-limiter in `VoiceChain` (limiter guards the boost). Persisted: `mv.loudnessNorm`,
  `mv.loudnessTarget`. OFF by default → default output unchanged. `VoiceChain` activates for
  `loudnessActive` even when polish/clarity are off (limiter must run).
```

- [ ] **Step 4: `docs/knowledge/timeline1.md`** — append a dated changelog entry (match the existing format):

```markdown
## 2026-06-15 — Metering & Loudness added

Added one render-thread telemetry layer (lock-free scalars) feeding a Live HUD
(input/output level, sample-peak + CLIP flag, "AI working hard" activity derived
from per-bin suppression, added-latency readout) and an ITU-R BS.1770 `LoudnessMeter`
(K-weighting → momentary + gated-integrated LUFS, sample-peak). Added optional
loudness normalization: a slew-limited make-up gain toward −14/−16 LUFS applied
pre-limiter in `VoiceChain` (persisted `mv.loudnessNorm` / `mv.loudnessTarget`, OFF
by default). v1 ships sample-peak (not oversampled true-peak) per the perf mandate.
UI: HUD in the popover, loudness panel in Settings. Replaced the per-callback
`inputLevel` main-thread hop with a ~25 Hz timer snapshot.
```

- [ ] **Step 5: `docs/knowledge/knowledge1.md`** — append a `[DECISION]` entry (detect username via `git config user.name`):

```markdown
## 2026-06-15 — [DECISION] Sample-peak (not true-peak) + lock-free render→main telemetry (@<username>)

**Problem**: Metering needs render-thread data (levels, peaks, suppression activity, loudness)
without locks/allocation, and a "true-peak" meter naïvely needs ≥4× oversampling on every buffer.
**Decision**: (1) Telemetry = plain `Float`/`Int32` scalars written render→main, snapshotted by a
~25 Hz timer — the suppression-knob atomic-scalar pattern, reversed; no locks, no per-buffer main hop.
(2) v1 ships **sample-peak + a clip flag**, NOT oversampled true-peak (too heavy for an always-on
menu-bar utility); the normalization ceiling is a peak-safe limiter labeled ~−3 dB, not certified dBTP.
(3) AI "confidence" is a derived heuristic (energy-weighted `1 − wetMag/dryMag` from the blend), a UX
hint only. (4) Integrated LUFS uses a bounded block log (no unbounded sample history).
**Rule**: Render→main telemetry must be lock-free scalars snapshotted at modest UI rate; never claim
certified true-peak without oversampling; keep all loudness math in the pure `LoudnessMeter` type.
**Files**: `Sources/Core/AudioProcessing/LoudnessMeter.swift`, `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`, `Sources/Core/AudioProcessing/VoiceChain.swift`, `Sources/Core/AudioModel.swift`
```

- [ ] **Step 6: Commit**

```bash
git add README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document Metering & Loudness (telemetry, LUFS, normalization)"
```

---

## Manual smoke test (after all tasks)

The headless suite cannot exercise the live audio path. After implementation, verify in the running app:

> **Note:** Metering of the OUTPUT and the AI-activity signal only update while **Noise Cancellation is ON** (the render callback writes telemetry inside the `if isAIEnabled` branch). The input meter and LUFS of the processed stream update whenever audio flows.

1. `./install-app.sh` (or `swift run`), open the popover.
2. Speak — confirm the **input** meter moves and the new **output** meter moves; both track your voice.
3. Speak loudly / tap the mic — confirm the **CLIP** flag flashes red, then clears when you stop.
4. With background noise present, confirm the **AI** activity bar rises (more suppression) and falls in quiet.
5. Confirm the **latency** readout shows a stable number (~70 ms) and the **LUFS** readout shows a sensible negative value while speaking, "— LUFS" in silence.
6. Open **Settings → Loudness**: confirm the integrated LUFS number tracks your speech.
7. Toggle **Normalize Loudness** ON with target −14: speak softly, then loudly — confirm the level is gently pulled toward a consistent loudness **without pumping**; confirm it never clips (limiter).
8. Set target −16, confirm the consistent level drops accordingly.
9. Turn normalization **OFF** — confirm output returns to un-normalized and is identical to before (regression by ear).
10. Quit and relaunch — confirm the normalization toggle + target are restored (persistence).
11. CPU check: with everything on, confirm Activity Monitor shows no meaningful CPU increase vs. baseline (telemetry is scalar; the timer is 25 Hz).

---

## Self-Review (completed during authoring)

- **Spec coverage:** Live HUD (#6) → telemetry scalars (Task 6) + AI-activity (Task 4) + HUD UI (Task 7) showing input/output level, sample-peak + CLIP, AI confidence, latency. LUFS meter + normalization (#2) → `LoudnessMeter` momentary + gated-integrated (Tasks 1–2), `normalizationGain` (Task 3), pre-limiter make-up in `VoiceChain` (Task 5), wiring + persistence (Task 6), Settings panel (Task 7). One shared telemetry layer → Task 6 owns the single scalar set + timer.
- **Honesty calls stated:** sample-peak (not oversampled true-peak) for v1 — Context + Task 7 copy + docs; momentary (live) + gated-integrated LUFS, no short-term — Context; AI-confidence is a derived heuristic, not a model output — Context + Task 4 comment.
- **Hard-constraint compliance:** render thread allocation-free + lock-free scalars (Context point 1–2, Tasks 4–6 perf notes); coefficient recompute on main only (`LoudnessMeter`/`VoiceChain` configured on main; gain is a scalar store); pure testable types in `Tests/NoNoiseMacTests` (Tasks 1–5); `AudioModel` verified by build + smoke (Task 6); `mv.*` persistence, no "MetalVoice"/"Ghostkwebb" in Sources, repo-relative paths only.
- **Open decisions surfaced for the executor:** (Task 6 Step 9) adding `loudnessActive` to `VoiceChainSettings` so normalization works with polish+clarity off; (Task 7 Step 2) `MeterView` ×5 internal scale vs. a dedicated scaled meter; (Task 2 Step 3) the bounded block-log cap for the relative gate. Each is flagged inline with a stated default.
- **Type consistency:** `LoudnessMeter` (`process`, `momentaryLUFS`, `integratedLUFS`, `samplePeak`, `reset`, `silenceLUFS`, `loudness(meanSquare:)`, `normalizationGain(...)`), `DeepFilterNetDSP.binActivity(dryMag:wetMag:)` + `aiActivity`, `VoiceChain.setLoudnessGain(_:)` + `loudnessActive`, `AudioModel` telemetry `@Published`s + `mv.loudnessNorm`/`mv.loudnessTarget`, are used consistently across tasks.
- **Placeholder scan:** none — every code step shows complete code or an explicit, bounded implementation note with the test that gates it.
