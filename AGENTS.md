# NoNoise Mac — Agent Operating Guide

This file is the entry point for any AI agent (or human) working in this repo. Read it
first, then the linked knowledge base before touching audio code.

## What this is
NoNoise Mac is a macOS (Apple Silicon) **menu-bar app** that removes background noise and
room reverb from your microphone **in real time, 100% on-device**, using **DeepFilterNet3**
on **CoreML + Metal / Accelerate**. It routes the cleaned voice through a virtual audio
cable so any app (Zoom, Meet, Discord, OBS, …) receives studio-clean audio.

## ICP / Who We Build For
- macOS **Apple-Silicon** users on calls, podcasts, livestreams, and screen recordings who
  need clean voice **without** cloud processing or a subscription.
- **Privacy-conscious** users — no audio ever leaves the machine.
- Creators who want light studio polish (EQ + leveling) without opening a DAW.
- **Not** for: Windows/Linux, Intel Macs, or multi-channel music mastering.

## Architecture map
- `Sources/Core` — engine, no UI:
  - `AudioModel` — playback + preset/knob state + persistence, ring buffer, render callback. Mic
    capture itself goes through the `MicCaptureBackend` protocol (below), NOT AVCapture directly —
    `AudioModel` keeps only the permission API (`AVCaptureDevice.authorizationStatus`/
    `requestAccess`), device discovery (`AVCaptureDevice.DiscoverySession`), and default-device
    lookup (`AVCaptureDevice.default(for:)`).
  - `MicCaptureBackend` — protocol for a single mic-capture producer (`configure(deviceUID:) ->
    Bool`, `start()`/`stop()`/`isRunning`, an `onAudio` callback) plus `MicDevice` (the pure
    uid/name value type `AudioModel.inputDevices` is made of). Injected into `AudioModel.init(micBackend:)`
    (defaults to `AVCaptureMicBackend()`, so existing call sites are unaffected). Two implementations
    exist: `AVCaptureMicBackend` (always available, the fallback) and `VoiceIOEngine` (Apple Voice
    Processing I/O, gated behind `mv.voiceProcessing` — see "Voice Processing I/O (VPIO)" below).
    `AudioModel` holds BOTH (`avCaptureBackend: MicCaptureBackend` + `voiceIOEngine: VoiceIOEngine?`)
    and routes `ingest()` through whichever is `currentBackend` — exactly one is ever wired to
    `onAudio` at a time (the `t*` telemetry scalars assume a single producer).
  - `AVCaptureMicBackend` — the `MicCaptureBackend` built on `AVCaptureSession` +
    `AVCaptureAudioDataOutput`; the `AVCaptureAudioDataOutputSampleBufferDelegate` conformance and
    the CMSampleBuffer → 48 kHz mono `AVAudioConverter` pipeline live here (moved out of
    `AudioModel`), including the render-callback-adjacent `configure`/`start`/`stop` contract:
    `configure` returns `true` only if an input was actually attached (device resolved AND the
    session accepted it), so a failed configure never reaches `start()`.
  - `AudioProcessing/VoiceIOEngine` — the `MicCaptureBackend` built on Apple Voice Processing I/O
    (`inputNode.setVoiceProcessingEnabled(true)`), an app-side AEC fix for the built-in-speaker echo
    problem. ALSO owns a paired playback graph (VPIO's echo canceller only references audio this
    process plays through its own output bus) that `IncomingCleanupEngine`/`SpeakerCleanupEngine` can
    hook into via `restart(withHook:owner:)`. See "Voice Processing I/O (VPIO)" below for the full
    contract (hook lifecycle, no output-device pin, fixed-format tap, runtime recovery).
  - `AudioProcessing/VoiceIOLogic` — pure, headless-tested decisions for VPIO: `VoiceIOStatus` +
    `FallbackReason` (the UI-facing effective-state enums), `CleanupPlaybackRoute`/
    `CleanupPlaybackTarget` (own-engine vs VPIO-hook playback routing), `CleanupRouteTransition.plan`
    (the ordered mutation list — `RouteMutation` — for moving a cleanup engine between routes, or
    tearing it down), `cleanupRoute`/`effectiveStatus`/`inputPinFailureReason`/`startFailureAction`,
    and `EchoRiskLogic` (the incoming card's built-in-speaker captions: the orange echo warning is
    suppressed while `voiceProcessingStatus == .active`, and a neutral "turn cleanup on" suggestion
    shows in the inverse configuration — display only, never auto-enables).
  - `AudioProcessing/MicFormatNormalizer` — per-tap-buffer format VALIDATION (mono/48 kHz, matching
    the tap's own fixed format) for `VoiceIOEngine`. No resampling: a non-48k input bus abandons VPIO
    entirely (see below) rather than converting.
  - `AudioLatency` — the pipeline's fixed sample rate (48 kHz) and latency budget (ring-buffer
    target + one STFT hop) as named constants, shared by `AudioModel`'s render callback,
    `AVCaptureMicBackend`'s capture-side target format, and `IncomingCleanupEngine`/
    `SpeakerCleanupEngine`'s latency trim — previously four separate hardcoded literals.
  - `AudioProcessing/DeepFilterNetDSP` — STFT → DeepFilterNet feature pipeline → CoreML call → ISTFT → wet/dry blend.
  - `AudioProcessing/DeepFilterNet3_Streaming` — generated CoreML model wrapper.
  - `AudioProcessing/VoiceChain` + `Biquad` + `Dynamics` — post-DSP "voice polish" (high-pass → shelves → compressor → limiter) plus the optional **Broadcast Voice** clarity stages (presence peaking bell → subtractive `DeEsser`) and optional **Mouth Noise** finisher stages (subtractive `DePlosive` → broadband-gate `DeClick`). Driven by `ClarityLevel` + `MouthNoiseLevel`, each is gated independently of the noise preset.
  - `AudioProcessing/IncomingCleanupEngine` — a SECOND, independent capture→clean→play pipeline ("clean the other side"), **macOS 14.4+**. Captures **all system audio except NoNoise** via a Core Audio **process tap** (no BlackHole/loopback), runs its OWN `DeepFilterNetDSP` instance (DFN only — **no** `VoiceChain`), and re-renders the cleaned audio to the **current default output** (auto-following device changes; tapped originals muted). NOT an `AudioModel` (no mic coupling, no auto-route to the NoNoise Mic sink). Held by `AudioModel` as an OPTIONAL (stored `AnyObject?`, gated type) created ONLY while enabled. The tap IOProc → `AVAudioSourceNode` are bridged by the lock-free `TapAudioRing` / `CTapRing` SPSC ring. Built with a `CleanupPlaybackTarget` (`.ownEngine`, the default, OR `.external` when VPIO owns playback — see "Voice Processing I/O (VPIO)" below). See "Incoming / guest cleanup" below.
  - `AudioProcessing/TapAudioRing` + `Sources/CTapRing` (`tap_ring.{c,h}`) — a lock-free C11-atomics single-producer/single-consumer float FIFO bridging the two realtime threads of the tap-based incoming path. Mirrors the driver's tested `nn_ring` acquire/release discipline.
  - `AudioProcessing/IncomingTapLogic` — pure, headless-tested decisions for the incoming path (own-process-object validity, re-pin-vs-rebuild) + the `IncomingCleanupStatus` enum the UI binds to.
  - `AudioProcessing/RingBuffer`, `SpecHistoryRingBuffer`, `AudioUtils` — buffers + helpers.
  - `VoicePreset` — preset → DSP params + voice-chain settings (single source of truth).
  - `CLIArguments` + `AudioDenoiseOptions` — shared CLI parser (live device, `--action`, `--denoise`).
  - `AudioFileDenoiser` — offline file decode → mono 48 kHz → `DeepFilterNetDSP` → optional `VoiceChain` → write WAV/CAF/etc. Waits on `DeepFilterNetDSP.waitUntilReady()` before processing; writes to a temp sibling then moves on success.
- `Sources/App` — SwiftUI menu-bar app: `NoNoiseMacApp`, `ContentView` (popover), `SettingsView`, and `LaunchAtLoginManager` (macOS Service Management adapter).
- `Sources/CLI` — `NoNoiseMacCLI`: live device pipeline, one-shot `--action` URL dispatch, and `--denoise` offline file mode (audio containers only — no MP4/video remux in v1).
- `Resources` — `DeepFilterNet3_Streaming.mlmodelc`, `AppIcon.icns`, `NoNoiseMacLogo.png`, `Info.plist`, `NoNoiseMac.entitlements`.
- `Tests/NoNoiseMacTests` — pure DSP / preset / voice-chain unit tests (run headless).

Launch at Startup uses macOS `SMAppService.mainApp` as the system-owned source of truth. It does
not duplicate state in `UserDefaults`, create a LaunchAgent/helper, or add an entitlement; the
setting works only when the installed app is running as a bundled application.

## Build, run, test
```bash
swift build                 # debug
swift build -c release --arch arm64  # optimized Apple Silicon release (bundle.sh prerequisite)
swift test                  # headless unit tests (+ one CoreML file-denoise integration test)
./bundle.sh                 # → NoNoiseMac.app + NoNoiseMacCLI (codesigned w/ entitlements)
./bundle.sh --with-driver   # also builds NoNoiseMic.driver and stages it NEXT TO the app
./install-app.sh            # arm64 release build + bundle + install to /Applications
./install-app.sh --with-driver # same, also stages NoNoiseMic.driver next to the app
./build-pkg.sh              # → NoNoiseMac-<ver>.pkg one-click installer (run AFTER ./bundle.sh --with-driver)
```
The virtual mic has its own scripts: `./build-driver.sh`, `sudo ./install-driver.sh`,
`sudo ./uninstall-driver.sh` (see "NoNoise Mic virtual driver" below). The driver is staged as a
sibling of the app, never nested inside the signed `.app`.
Release installs MUST build with `--arch arm64`; NoNoise Mac is Apple-Silicon-only, and release
builds are the optimized path for M-series chips.
The app is a menu-bar utility (`LSUIElement`); **AI noise cancellation is ON by default**
(`AudioModel.isAIEnabled = true`).

## Apple Silicon performance mandate
NoNoise Mac is an always-available menu-bar audio utility for M-series Macs. Every implementation
decision MUST preserve that feel: low CPU, low memory churn, low latency, and no avoidable battery
drain. Optimize for Apple Silicon first (`arm64`, CoreML/Metal/Accelerate where appropriate), and
write high-performance code by default. Never introduce work that can noticeably slow down the
user's Mac, pin the CPU/GPU, allocate in hot paths, poll unnecessarily, or keep hardware active
without a measured reason.

Performance does not outrank correctness, privacy, or audio quality. If a faster approach would
reduce output quality, weaken privacy, or make behavior harder to reason about, do not take it.
Instead, keep the quality bar and find a measured, maintainable optimization. Any non-trivial
performance-sensitive change should be verified with the closest available signal: tests,
Instruments/profiling, allocation checks, or an explicit before/after explanation.

## CI & releases
`.github/workflows/ci.yml` runs on pushes to `main` and pull requests targeting `main`; it only
builds and tests. **Pushes to `main` do NOT publish a release** — releases are versioned-only.
`.github/workflows/release.yml` publishes a GitHub release ONLY for `v*` tags whose commit is
contained in `origin/main` (cut via `release.sh`), or a manual `workflow_dispatch`. Assets use
tag-specific filenames (`NoNoiseMac-<tag>.app.zip`, `NoNoiseMacCLI-<tag>.zip`,
`NoNoiseMic-driver-<tag>.zip`, `NoNoiseMac-<tag>.pkg`, `SHA256SUMS-<tag>.txt`) PLUS an un-suffixed
copy `NoNoiseMac.pkg` so the fixed link `…/releases/latest/download/NoNoiseMac.pkg` always resolves
to the newest installer — the team guide (`docs/deploy/team-install.md`) links ONLY that URL, so
never drop or rename that asset. The `.pkg` (built by `build-pkg.sh`) is the one-click app+driver
installer — unsigned until `PKG_SIGN_IDENTITY` is set in CI (team decision 2026-09-28: stay unsigned;
revisit Developer ID + notarization if ≥2 members stall on the Gatekeeper step or monthly updates
become routine). A Google Drive copy of the pkg is a MANUAL mirror refreshed per release; GitHub
Releases is the source of truth. Do NOT re-add the `workflow_run` rolling
`main-<short-sha>` "stable" releases: they stole GitHub's **Latest** badge from versioned releases
and cluttered the Releases page. (A one-off stable build is still available via
`workflow_dispatch` with tag `stable-latest`.) Also do NOT reintroduce a moving `stable` Git tag —
`git pull --tags` rejects moved local tags and breaks normal sync.

## How to cut a versioned release (AI agent instructions)

Use `release.sh` — do NOT create tags manually. The script bumps the version in `Info.plist`,
commits, creates an **annotated** git tag carrying the release notes, then pushes both to trigger
CI. The release notes in the tag body become the GitHub release description.

**Step 1 — write the release notes to a file:**

```markdown
## What's New

- Concise, user-facing description of each new feature or improvement.
  Start with a verb: "Added X", "Improved Y", "Removed Z".
  One bullet per item. No implementation details — say what it does for the user.

## Bug Fixes

- What broke and what it does now. One bullet per fix.
  Example: "Fixed audio dropout when switching input devices during an active session."

## Notes

- Breaking changes, migration steps, known limitations, or anything the user must act on.
  Omit this section entirely if there's nothing to say.
```

**Rules for good release notes:**
- Only include sections that have content — omit empty ones entirely
- No version number in the notes body (the release title already has it)
- No marketing language — users are technical, be direct
- Do NOT add an install or signing note — CI appends it automatically
- Keep bullets to one line each; wrap long bullets with a sub-list if needed

**Step 2 — run the release script:**

```bash
./release.sh <version> --notes-file /path/to/notes.md
# Example:
./release.sh 1.3.0 --notes-file /tmp/release-notes.md
```

The script requires:
- You are on the `main` branch with no uncommitted changes
- Version is semver (`major.minor.patch`, e.g. `1.3.0`)
- The notes file is non-empty

**What happens next:** `release.sh` pushes main + the tag AND dispatches `release.yml` via `gh`
(**push/tag events do NOT start workflows on this fork** — verified 2026-09-28 — only
`workflow_dispatch` runs; `ci.yml` therefore also has `workflow_dispatch`, start it with
`gh workflow run ci.yml -R korezonzi/NoNoise-Mac --ref main` after pushing — ALWAYS pass `-R`: with two
remotes, a bare `gh` resolves to the UPSTREAM repo and fails with HTTP 403). CI builds arm64 binaries, bundles the app +
CLI + driver, and publishes the GitHub release with your notes plus the standard install footer.
Takes ~10–15 min on the macOS runner. If a release run fails AFTER publishing (e.g. asset upload),
re-dispatch with the same tag — the publish step is idempotent.

## Entitlements & signing
`bundle.sh` codesigns with `Resources/NoNoiseMac.entitlements`, kept **intentionally minimal** —
exactly two keys:
- `com.apple.security.device.audio-input` — the app captures the microphone.
- `com.apple.security.cs.allow-jit` — required by the CoreML/Metal backend: DeepFilterNet3 runs on
  the GPU/Neural Engine and Metal shader compilation JITs under the hardened runtime, so removing
  this can break model inference at runtime.

Do not add entitlements beyond these two without a measured, documented need.

## Auto-update (Sparkle) — REMOVED in this fork
- **There is no in-app updater.** Sparkle was removed on 2026-07-17 (`e1bc8a6`): `Package.swift` has
  no Sparkle dependency and `Sources/App/UpdaterController.swift` is a no-op stub that keeps the
  "アップデートを確認" button permanently disabled. Users update by re-downloading the pkg from the
  fixed link (see "CI & releases"); `release.yml` no longer generates or publishes an appcast.
- **Inert leftovers — do not "fix" them:** `Resources/Info.plist` still carries `SUFeedURL` (pointing
  at the UPSTREAM repo), `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`.
  Nothing reads them. If Sparkle is ever re-introduced, the feed URL MUST be re-pointed at this fork
  first, or users would be served upstream's builds.
- **`CFBundleVersion` is still a MONOTONIC INTEGER** (`MAJOR*1000000+MINOR*1000+PATCH`), NOT semver.
  `scripts/version-from-tag.sh` is the single source of that mapping (tested by
  `scripts/version-from-tag.test.sh`); **`release.sh` calls it** to stamp `Info.plist`. Keep the rule
  even without Sparkle — macOS Installer and any future updater compare it. Keep minor/patch < 1000.
- **Versioning is owned by `release.sh`** (it bumps + commits + tags). CI does NOT re-stamp; it
  trusts the committed `Info.plist`.
- **`bundle.sh` signs ad-hoc, never `--deep`.** No Hardened Runtime, no notarization.

## Branding & identifier conventions (do not regress)
- Display name: **NoNoise Mac**. Code identifier: **NoNoiseMac** (executable, SwiftPM
  package + targets, class prefix, asset filenames). Bundle id: **com.korezonzi.NoNoiseMac.r2**
  (rotated whenever macOS 26's menu-bar management DB poisons the current id — twice so far; see
  the header note in `Sources/App/NoNoiseMacApp.swift` and the migration chain there). The DRIVER
  bundle id stays **com.ivalsaraj.NoNoiseMic** (unaffected by the app-side rotations).
  CLI binary: **NoNoiseMacCLI**.
- The old names **MetalVoice / Ghostkwebb** may appear **only** in credit/provenance:
  `README.md` credits, `LICENSE` original copyright, this provenance note, and `docs/`
  history. **Never** in `Sources/`, `Package.swift`, `Resources/`, `bundle.sh`,
  `CONCEPTS.md`, `CONTRIBUTING.md`, or `.github/`.
- Internal `UserDefaults` keys use the legacy `mv.*` namespace — they are invisible to users
  and intentionally left unchanged to avoid migration churn. Do not "rebrand" them.

## Agent store & knowledge base (AI-native)
- **Agent catalog** — who to invoke for what: [`docs/agents/README.md`](docs/agents/README.md).
- **Compounding knowledge** — gotchas, decisions, timeline: [`docs/knowledge/INDEX.md`](docs/knowledge/INDEX.md).
- **Domain glossary**: [`CONCEPTS.md`](CONCEPTS.md).
- ⚠️ Read [`docs/knowledge/critical-patterns.md`](docs/knowledge/critical-patterns.md)
  **before** modifying the CoreML call or the render thread — both have shipped-and-broke
  failure modes.

---

## DSP architecture invariants
- The CoreML model is **stock DeepFilterNet3** (sr 48000, fft 960, hop 480, 481 bins, 32 ERB bands, nb_df 96). The caller MUST reproduce libDF's feature pipeline exactly (`libDF/src/lib.rs` / `transforms.rs`). The three model inputs map to DFN's `spec` / `feat_erb` / `feat_spec`:
  - **spec_buf** = RAW complex spectrum `wnorm * FFT(window * x)`, `wnorm = 1/960`, **un-normalized, no compression**. Absolute scale matters — it is fed raw.
  - **feat_erb** = contiguous mean-power ERB bands (`erb_fb` partition, `k = 1/band_size`) → `10*log10(p + 1e-10)` → `(x - mean)/40`, mean EMA init `linspace(-60, -90, 32)`.
  - **feat_spec** = first 96 complex bins, unit-normed `x / sqrt(state)`, state EMA init `linspace(0.001, 0.0001, 96)`. **No power compression** anywhere.
  - **window** = Vorbis `sin(π/2 · sin²(π(n+0.5)/N))` for both analysis & synthesis (Princen-Bradley → unity OLA).
  - **enhanced_spec output** = RAW enhanced complex spec in the same wnorm scale → ISTFT directly. **Do NOT de-normalize or de-compress** the output (doing so attenuates highs and muffles the voice). Synthesis uses NO `1/N` (analysis `wnorm` + unnormalized inverse DFT already give unity).
  - There is **no spectral compression exponent** in DFN's feature path. A prior reimplementation invented one (`c=0.5/0.6`) plus an output de-normalization; both were bugs that muffled speech. Don't reintroduce them.
- **CoreML I/O dtype boundary — READ THIS BEFORE TOUCHING THE MODEL CALL:**
  - The model runs `computeUnits = .all` (Neural Engine / GPU). Its outputs (`enhanced_spec`, `h_enc_out`, `h_erb_out`, `h_df_out`) are Float16 `MLMultiArray`s produced off-CPU.
  - **NEVER read those output arrays with raw `withUnsafeBufferPointer(ofType: Float16.self)`.** On ANE/GPU outputs this reads back as **zeros** → `realOut`/`imaginaryOut` go silent → **the app produces no audio when AI is on**. This actually shipped and broke playback. Read outputs via the `NSNumber` subscript (`enhanced[[...] as [NSNumber]].floatValue`, `oEnc[i].floatValue`) which forces correct CPU materialization.
  - Writing to **input** arrays we allocate ourselves (`specBufIn`, `erbBufIn`, `featSpecBufIn`) via `withUnsafeMutableBufferPointer(ofType: Float.self)` IS safe — those are plain CPU-backed buffers. Hidden-state inputs (`hEncIn`/`hErbIn`/`hDfIn`, `.float16`) are written via `NSNumber(value:)`.
  - Bottom line: buffer pointers are fine for arrays WE allocate and fill; `NSNumber` is mandatory for arrays the MODEL fills.
- `Sources/Core/AudioProcessing/DeepFilterNet3_Streaming.swift` is generated, but its unused
  `MLShapedArray<Float16>` conveniences are intentionally gated behind `#if compiler(>=6.0)`.
  GitHub Actions currently builds with Swift 5.10, where that Float16 conformance is unavailable on
  macOS. If the wrapper is regenerated, preserve the gate or remove the shaped-array conveniences.
- Hidden state (`h_enc_buf`, `h_erb_buf`, `h_df_buf`) is stored as `[Float]` and bridged to/from the model via `NSNumber`. Do not "optimize" to `[Float16]` + raw buffer reads — the read-back comes from a model output array (see above).

## Real-time audio rules
- `processHop` runs on the AVAudioEngine render thread. **No avoidable heap allocations in `processHop`**: all hop-local scratch (`windowedInput`, `magSqScratch`, `erbFeatScratch`, `rawSpecScratch`, `recoveredRealScratch`, `recoveredImagScratch`, `featSliceScratch`, `zeroHopScratch`) and all input `MLMultiArray`s (`specBufIn`, `erbBufIn`, `featSpecBufIn`, `hEncIn`, `hErbIn`, `hDfIn`) are stored on the class and pre-allocated in `init()`. **Mutate them directly** (e.g. `magSqScratch[i] = ...`) — do NOT bind them to a local `let`/`var` first; Swift arrays COW-copy on first mutation through a local binding, defeating the purpose. For vDSP-style inout pointer APIs (`vDSP_DFT_Execute`, `vDSP_vmul`, `vDSP_vsmul`, `vDSP_vadd`), use `withUnsafeMutableBufferPointer` on the stored property and pass `baseAddress!`.
- All ML feature history (spec / erb / feat-spec) goes through `SpecHistoryRingBuffer` — never use Swift `Array.removeFirst` on a long-lived feature buffer.
- `process(input:count:output:)` (the outer entry point, not `processHop`) **does** still allocate an `Array(...)` for the input chunk. That is acceptable; the render callback runs on a background queue and the cost is bounded by `count`. Do not "fix" this without first measuring.
- The ML model produces **fresh** output `MLMultiArray`s each prediction (CoreML's API contract). Only the *input* `MLMultiArray`s are pre-allocated and reused; output arrays are not.
- Pre-allocated `MLMultiArray`s are safe to reuse because `prediction(input:)` is synchronous and the DSP is single-threaded.

## Presets & intensity knobs
- `DeepFilterNetDSP.suppressionStrength` (wet/dry mix, 0..1) and `attenuationLimitDb` (max reduction; `>= maxAttenuationLimitDb` disables the floor) are read on the render thread, written from main — **same plain-`var Float` pattern as `outputGain`**. Do NOT add locks; 32-bit aligned scalar stores/loads are atomic on arm64.
- The output blend lives in pure static helpers `minGain(forAttenuationDb:)` and `resolveOutputBin(...)` so the math is unit-testable WITHOUT the CoreML model. The default case (`strength >= 1 && minGain <= 0`) takes a fast path returning the enhanced value unchanged — this keeps the default **byte-for-byte identical** to the pre-preset output. Keep new DSP math in testable statics, not inline-only.
- The blend reads the dry spectrum from `rawSpecScratch` (the raw wnorm-scaled complex spec retained in feature extraction). Wet (`enhanced`) and dry are in the SAME wnorm domain — do not blend across scales.
- `VoicePreset` (Core) is the single source of preset values: `.auto` / `.strong` / `.medium` / `.weak` / `.custom` (labels 自動/強/中/弱/カスタム). `maxAttenuationDb` MUST equal `DeepFilterNetDSP.maxAttenuationLimitDb` (a test enforces this). UI binds to `AudioModel.selectedPreset`; manual knob moves flip it to `.custom` via `onKnobChanged()`. The `isApplyingPreset` flag prevents the apply→didSet→custom feedback loop — never remove it. A direct `.custom` selection is persisted by `selectedPreset.didSet` (NOT `applyPreset`). `VoicePreset.migratingRawValue(_:)` is the single place the pre-redesign names (meeting/podcast/tutorial) map onto their numeric equivalents (strong/medium/weak) — both `AudioModel.loadSettings` (`mv.preset`) and `VoicePreset`'s own `Decodable` (used when decoding a `VoiceProfile` saved before the redesign) route through it; `CLIArguments`' `--preset` accepts both name sets via the same function.
- **`.auto`** starts at `.medium`'s numbers, then `AudioModel.updateAutoStrength()` (called every control-pump tick, see "Metering & loudness" below) drives live `suppressionStrength`/`attenuationLimitDb` toward `.weak`/`.medium`/`.strong` via `AutoStrengthController` (Core/AudioProcessing) — a pure, headless-tested EMA + hysteresis (~30 s time constant, ~3 s stage-hold) over `DeepFilterNetDSP.aiActivity`, mirroring `SmartLevelController`'s "stateless enum + caller-owned `State`" design. Stage changes apply via `AudioModel.applyAutoStage(_:)` (same `isApplyingPreset` guard as `setOutputGainForSmartLevel`) and are NEVER persisted — only the `.auto` selection itself survives a relaunch; `autoStrengthState` resets to a fresh `.medium` start every time the preset (re)selects `.auto` (`AudioModel.syncAutoState(for:)`, called from `applyPreset`/`applyProfile`/`onKnobChanged`/`loadSettings`/`resetSettingsToDefaults` — several of those set `selectedPreset` directly under the `isApplyingPreset` guard and so never reach `applyPreset`'s own call). The current stage is published as `AudioModel.autoCurrentStage` (`VoicePreset?`, non-nil only while `.auto` is active) for the UI's "自動（いま：中）" caption — written only on an actual stage change or preset transition, NEVER unconditionally from the 25 Hz pump (would reintroduce the SwiftUI invalidation storm the meter-telemetry split removed).
- Preset + knob state persists in `UserDefaults` under `mv.*` keys; first launch (no `mv.preset`) defaults to `.auto`. `AudioModel` itself is not unit-tested (its `init()` starts CoreAudio/AVFoundation) — the pure logic (`VoicePreset`, `AutoStrengthController`) is unit-tested and the orchestration is smoke-tested.
- Settings reset uses `SettingsResetPolicy`: reset audio/device keys to defaults, but preserve user-created assets (`mv.profiles`) and custom hotkey bindings (`mv.hotkey.*`). Add future resettable app/audio keys to `SettingsResetPolicy.resettableKeys`; do not duplicate `mv.*` key strings elsewhere.
- **Input-device selection contract**: `AudioModel.inputDeviceSelection` (persisted `mv.inputDeviceUID`,
  reset by `SettingsResetPolicy`) is either `VirtualMicRouting.autoInputSelection` (`"auto"`, the
  default — follow the system default input, so earphone connect/disconnect switches the mic
  automatically via the existing default-input HAL listener → debounced refresh) or a manual device
  UID. The EFFECTIVE device stays `selectedInputDeviceID`, which is NEVER persisted and is
  re-derived by the pure, unit-tested `VirtualMicRouting.resolveInputDeviceUID` (fallback — manual:
  saved → default → current → first; auto: default → current → first; the NoNoise self-capture loop
  is prevented by membership in the `filterInputs`-cleaned list, not by a special case). A direct
  `selectedInputDeviceID` write from outside is DISCARDED on the next device refresh — external
  callers (e.g. the CLI's `--in`) must set `inputDeviceSelection` instead. Deliberately NOT part of
  `VoiceProfile` (device-dependent, not a "voice" setting); when the manual device is unplugged the
  UI must show which mic actually took over (orange caption in `devicesCard`).

## Voice polish chain (Tier 2)
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → **presence (peaking bell) → de-esser → de-plosive → de-click** → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
- Built from pure, unit-tested value types: `Biquad` (RBJ cookbook coefficients, TDF-II), `Compressor` (log-domain feed-forward), `Limiter` (fast peak + hard clamp). Keep all DSP math here, testable, with no CoreML dependency.
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2` for the high-pass, shelves, and presence bell; `Compressor.envDb`; `Limiter.gain`; `DeEsser` envelope + HP state; `DePlosive` low/high detection envelopes + `frac` + LP/HP filter state; `DeClick` peak follower + slow background + gain + hold/event-latch counters) carries across render buffers — never reset per buffer. `configure` resets state in exactly three cases: FULL reset on inactive→active (clean start); clarity-stages-only reset (`presence` + `DeEsser`) when `ClarityLevel` changes while active; mouth-noise-stages-only reset (`DePlosive` + `DeClick`) when `MouthNoiseLevel` changes while active. All other active→active switches are intentionally bumpless.
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage) plus the orthogonal **Broadcast Voice** `ClarityLevel` and **Mouth Noise** `MouthNoiseLevel`. The chain runs when `(voicePolishEnabled && preset.voiceChain.enabled) || clarity != .off || mouthNoise != .off`. Every preset (`.auto`/`.strong`/`.medium`/`.weak`/`.custom`) returns the SAME `voiceChain` settings with `enabled = true` (the old Meeting-only `.disabled` gate is gone) — so that expression is now effectively just `voicePolishEnabled`; Broadcast Voice (presence + de-esser) and Mouth Noise (de-plosive + de-click) layer on any mode independently. Persisted: `mv.voicePolish`, `mv.clarity`, `mv.mouthNoise` (plus the Tier 1 `mv.preset`). `configure` resets ALL stage state on inactive→active; resets ONLY clarity stages when `clarity` changes while active; resets ONLY mouth-noise stages when `mouthNoiseLevel` changes while active (bumpless otherwise).
- `applyVoiceChain()` reconfigures the chain on every preset transition (explicit pick AND the auto-flip to Custom) and on toggle/load — never from the per-tick knob path more than once per transition. `voicePolishEnabled.didSet` is guarded by `!isApplyingPreset` exactly like the Tier 1 knobs.
- A **Voice Profile** is a named snapshot of ALL user-tunable settings (`selectedPreset`, `suppressionStrength`, `attenuationLimitDb`, `outputGainValue`, `voicePolishEnabled`, `clarityLevel`) persisted as a JSON array under `mv.profiles`. Applying a profile goes through the same `isApplyingPreset` guard as `applyPreset` + `applyVoiceChain` — all `@Published` properties are set inside `isApplyingPreset = true … = false`, then a single `applyVoiceChain()` and `persistSettings()` are called after. This prevents spurious `onKnobChanged` → `.custom` flips or redundant persists mid-apply. Future settings fields must be added to `VoiceProfile` as optionals (schema version stays at 1) so old profiles survive without migration.

## CLI offline file mode
- **Four CLI modes** (mutually exclusive): live device `--in`/`--out`, one-shot `--action`, offline `--denoise`/`--output`, and the dev-only `--aec-spike <scenario>` diagnostic mode. Parser lives in `Sources/Core/CLIArguments.swift` (unit-tested).
- **Offline path** — `AudioFileDenoiser` decodes with AVFoundation, waits on `DeepFilterNetDSP.waitUntilReady()`, streams mono 48 kHz through DFN then preset `VoiceChain`, writes via temp file + atomic move. MP4/video remux is explicitly out of scope.
- **Preset knobs** — `--preset` resolves DSP defaults from `VoicePreset.parameters`; explicit `--gain` / `--strength` / `--attenuation-db` override after preset resolution (same precedence as the plan's parser tests).
- **`--aec-spike`** is a throwaway-adjacent feasibility harness for the Apple Voice Processing I/O echo-fix candidate (`Sources/Core/AudioProcessing/VoiceIOSpike.swift` + `AECSpikeAnalysis.swift`) — not a user-facing feature, deliberately hidden behind this flag.

## Control layer (Tier 4) — `Sources/Core/ControlLayer.swift`, `Sources/App/ActionDispatcher.swift`, `Sources/App/HotkeyManager.swift`

- **Core/App split (so it stays testable):** the PURE models — `ControlAction` (URL/CLI parsers
  + gain constants), `HotkeyActionID`, `HotkeyBinding`, `HotkeyModifier`, `ControlState`, and the
  `ControlReducer` state machine — live in `Sources/Core/ControlLayer.swift` and import only
  `Foundation`. The test target depends on `Core` only, so the REAL dispatch logic (bypass
  transitions, desired-vs-effective AI, gain clamping, cycling) is unit-tested via `ControlReducer`
  (`Tests/NoNoiseMacTests/ControlLayerTests.swift`) WITHOUT constructing `AudioModel`.
- `ActionDispatcher` (@MainActor, App) is a thin adapter: it reads a `ControlState` snapshot from
  `AudioModel`, runs `ControlReducer.reduce`, and applies the returned `[ControlMutation]`. It is the
  single dispatch point for all control actions. It is NOT headless-testable (depends on `AudioModel`
  → CoreAudio).
- **NEVER blanket-write AudioModel fields from the dispatcher.** The reducer returns an explicit
  `[ControlMutation]` (`.setAIEffective` / `.setPreset` / `.setClarity` / `.setGain`) naming EXACTLY
  what the action changed; the adapter applies ONLY those. This is load-bearing: `AudioModel`'s knob
  `didSet`s have side effects — writing `outputGainValue` (or suppression/atten) calls
  `onKnobChanged()` which flips a non-`.custom` preset to `.custom`; writing `selectedPreset` re-applies
  the preset's own gain/atten via `applyPreset`. A blanket "write every field back" would (a) demote
  the active preset to Custom on `.toggleAI`, and (b) override a just-applied preset's gain with the
  pre-change value on `.presetNext`. So `.toggleAI`/bypass emit only `.setAIEffective`; `.presetNext/
  prev` emit only `.setPreset` (no trailing gain write); `.gainUp/down` emit `.setGain` (the
  `onKnobChanged()` → `.custom` flip is the INTENDED manual-edit behavior).
- **A/B bypass = desired-vs-effective AI.** `desiredAIEnabled` is the user's intended AI on/off
  ignoring bypass; effective = `desiredAI && !(momentary || toggle bypass)`. `.toggleAI` ALWAYS
  flips `desiredAI` (even while bypassed); on bypass exit, `AudioModel.isAIEnabled` follows the
  current desired value. Firing toggle-AI mid-bypass therefore does NOT turn AI back on against the
  bypass. Bypass state is session-only (never persisted); `desiredAI` mirrors the persisted
  `isAIEnabled`. This is the only place `isAIEnabled` is written from outside its `didSet` path.
- **The popover master toggle binds to `dispatcher.aiToggleBinding`, NOT `$audioModel.isAIEnabled`,
  and is `.disabled(dispatcher.isBypassed)`.** A direct binding would let the user flip the UI toggle
  during bypass and write `isAIEnabled = true` straight onto the model, re-enabling AI against an
  active bypass (the desired-vs-effective rule's state hole). Routing through the dispatcher uses the
  same `.toggleAI` path; disabling it during bypass closes the hole (desired AI is still changeable by
  hotkey while bypassed).
- `HotkeyManager` (@MainActor, App) uses Carbon `RegisterEventHotKey` + `InstallEventHandler`.
  **Do NOT switch to `NSEvent.addGlobalMonitorForEvents`** — that requires Accessibility permission,
  violating the minimal-entitlement policy (AGENTS.md "Entitlements & signing"). Carbon hotkeys work
  with the existing two entitlements and no permission prompt.
- **Hotkeys register at app launch**, in `NoNoiseMacApp.init()` (HotkeyManager held on `@StateObject`),
  NOT in `ContentView.onAppear` — a `MenuBarExtra`'s content view isn't instantiated until the
  popover opens, so onAppear-registration would leave hotkeys dead until first click.
- **`appDelegate.dispatcher` is wired in `NoNoiseMacApp.init()`, NOT `ContentView.onAppear`** (same
  MenuBarExtra timing reason). The `@NSApplicationDelegateAdaptor` wrapped value exists before the
  `init()` body runs, so the assignment is valid there. Wiring in `onAppear` would leave the
  AppDelegate's `application(_:open:)` URL fallback with a nil dispatcher until the popover first
  opened — a bundled `.app` would drop `open nonoisemac://…` fired before any popover open.
- **`EventHotKeyID.id` is deterministic** (`HotkeyActionID.allCases` index + 1), NOT
  `rawValue.hashValue` — Swift's `hashValue` is randomized per process and would make the fired ID
  un-matchable back to its action.
- The Carbon C callback extracts the `EventHotKeyID` synchronously, then hops to the main actor via
  `Task { @MainActor in … }` before touching `HotkeyManager`/`ActionDispatcher` (both `@MainActor`).
- `HotkeyBinding` stores a plain `UInt32` modifier mask (Core `HotkeyModifier` bits, which equal the
  AppKit `NSEvent.ModifierFlags` device-independent bits). Core never imports AppKit; `HotkeyManager`
  / `KeyCaptureView` adapt `NSEvent.ModifierFlags` ↔ `UInt32` at the App boundary. Encodes as
  `"<keyCode>:<modifierMask>"`.
- Bindings persist under `mv.hotkey.*` keys (consistent with the existing `mv.*` namespace).
- If `RegisterEventHotKey` returns `eventHotKeyExistsErr` (-9878), the slot is left unregistered and
  surfaced in `conflictedActions` (shown in Settings → Hotkeys). Never crash.
- Gain nudge clamps to `0.5...4.0` — the SAME range as the Settings → General "Output Gain" slider
  (`SettingsView.gainCard`). Keep these in sync if the slider range ever changes.
- `nonoisemac://` URL scheme is registered in `Resources/Info.plist` (`CFBundleURLTypes`).
  **This only works in a bundled `.app`** — `swift run` / `swift build` do not register URL schemes.
  Test via `./bundle.sh` + opening `NoNoiseMac.app`.

## Metering & loudness (Tier 2)
- **Telemetry is lock-free scalars** written render→main (the reverse of the suppression knobs, same arm64 atomicity argument). This **reuses the Smart Level telemetry layer**: the render callback writes output level/peak/clip + LUFS snapshots via `recordOutputTelemetry(_:count:)`, and `DeepFilterNetDSP.aiActivity` is written in the blend loop. **Two main-thread timers consume them (menu-bar perf split):** an ALWAYS-ON ~25 Hz **control pump** (`startControlPump`/`runControlPump`) is the SOLE owner of the `t*` read-and-reset and runs BOTH control loops (Smart Level + loudness normalization), writing only a plain `MeterSnapshot` — it touches NO `@Published`, so it triggers zero SwiftUI invalidation. A **popover-gated** UI-publish timer (`beginMeterObservation(_:)`/`endMeterObservation(_:)`, driven by a per-source `Set<MeterObserver>` across the popover + Settings — idempotent, so duplicate/missed lifecycle events can't leak or double-start it) copies that snapshot into the `@Published` fields on `MeterModel`. NEVER add locks; NEVER push per-buffer to main; NEVER promote a `MeterSnapshot` field to `@Published` or move a control loop into the gated UI timer (that resurrects the 25 Hz storm / silently disables audio control when the popover is closed).
- **Live meters live on `MeterModel`, observed by scoped subviews ONLY.** The high-frequency `@Published` meter fields are on `MeterModel` (`Sources/Core/MeterModel.swift`), NOT `AudioModel` — so `AudioModel.objectWillChange` no longer fires on telemetry ticks. Only the small live-meter subviews observe it (`StatusMeters` / `LiveHUDCard` in the popover, `GeneralSettingsView` in Settings); do NOT bind the whole popover, a card, or the `MenuBarExtra` label to `MeterModel` — that re-introduces the Scene/popover re-render storm the split removed. A meter view drives the gated publish loop via `begin/endMeterObservation(_:)` with its source (popover: SwiftUI `onAppear`/`onDisappear`; Settings: `WindowManager` on the reused `NSPanel`'s create/`willClose` lifecycle, which is more reliable than `onDisappear` there). Seeding happens once on `begin` so the first frame after a closed interval is correct, not stale.
- **The `LoudnessMeter` struct is NEVER read cross-thread.** It is a value type mutated ONLY on the render thread (inside `recordOutputTelemetry`); the render thread copies its getters into the `tMomentaryLUFS` / `tIntegratedLUFS` scalars, and the UI timer reads only those scalars. Only plain 32-bit scalars cross threads (the blessed pattern) — do not read the meter object from main.
- **Output telemetry (level/peak/clip/LUFS) updates whenever audio flows** (`recordOutputTelemetry` runs unconditionally, like Smart Level's peak/clip), so the output meter is live in passthrough too. **AI activity** (`aiActivity`) is the one AI-gated readout — it reads 0 when `isAIEnabled` is false (no `processHop` runs). The **clip warning reuses Smart Level's `isOutputClipping`** (peak-threshold + clip-count), not a separate flag.
- **`LoudnessMeter` (Core/AudioProcessing)** owns all BS.1770 math (the REAL K-weighting biquads — published 48 kHz coefficients via `Biquad.setCoefficients`, NOT RBJ approximations — momentary + gated-integrated LUFS, sample-peak, and the `normalizationGain` helper) as a pure, headless-tested value type — same rule as `Biquad`/`resolveOutputBin`. Tested at multiple frequencies.
- **v1 is sample-peak, not true-peak** (oversampled dBTP deferred for perf). Do not relabel the peak as dBTP. Integrated LUFS uses a **fixed-size, pre-allocated block ring** (write by index, wraparound) — never an `append`-growing log; `process` stays allocation-free.
- **Loudness normalization** is a main-computed, slew-limited scalar `loudnessGain` applied pre-limiter in `VoiceChain` (limiter guards the boost). Persisted: `mv.loudnessNorm`, `mv.loudnessTarget`. OFF by default → default output unchanged. `VoiceChain` activates for `loudnessActive` even when polish/clarity are off (limiter must run); the `loudnessActive` field and `AudioModel.applyVoiceChain()` move together (one contract).
- **Receive-cleanup mini meter is PULL-based, last-value telemetry** (deliberate second pattern next
  to the `t*` read-and-reset): each cleanup engine stores its post-mix RMS into a heap `levelBox`
  (raw-pointer captured, allocation-free) plus its own `dsp.aiActivity`, and `runControlPump` PULLS
  `telemetryLevel`/`telemetryActivity` from whichever engine is non-nil (they're mutually exclusive)
  into `MeterSnapshot.incomingCleanup{Level,Activity}` — 0 when both are nil, so the meter decays
  when the feature is off/failed. No read-and-reset (no reset-ownership problem), no new `@Published`
  on `AudioModel`. The ONLY observer of the two `MeterModel` fields is the `IncomingActivityMeter`
  subview, shown only while the selected mode's status is `.cleaning`. The Speaker engine's silence
  bypass decays `aiActivity` itself (it skips `dsp.process`, the only other updater) so the AI bar
  can't freeze on a stale value.

## Input Volume & Smart Level (hot-mic guard)
- **Input Volume** is an app-level pre-DSP trim (`inputVolumeValue`, persisted `mv.inputVolume`, range 25%…100%, default 80%). Applied in `captureOutput(...)` after 48 kHz conversion and **before** `ringBuffer.write`. Does **not** write macOS hardware input volume.
- **Runtime scalar:** capture/render paths read `realtimeInputVolume` (mirrored from `inputVolumeValue` in `didSet`), never the `@Published` wrapper directly.
- **Telemetry:** scalar peaks written on capture/render threads (`tRawInputPeak`, `tTrimmedInputPeak`, `tOutputPeak`, clip/hot counters); the always-on ~25 Hz **control pump** (`runControlPump`) reads-and-resets them, runs Smart Level, and writes the plain `MeterSnapshot` (the popover-gated UI timer publishes it into `MeterModel`). No `DispatchQueue.main.async` from audio paths for metering.
- **Input meter = trimmed signal:** the meter's `inputLevel` is the **trimmed** RMS NoNoise actually processes, not the raw source level. `captureOutput` measures raw + trimmed in one allocation-free helper (`SmartLevelController.applyInputVolumeAndMeasure` — raw scan → in-place trim → trimmed scan), and `runControlPump` derives the input-side fields (`inputLevel`, `isInputNearCeiling`, `isSourceMicClipping`, `consecutiveTrimmedHotTicks`) from `SmartLevelController.evaluateInputGuard` into the `MeterSnapshot`. Raw peak still drives the source-clip warning separately.
- **Smart Level** (`smartLevelEnabled`, `mv.smartLevel`) is protective only — gradually reduces Input Volume when trimmed input is repeatedly near ceiling (≥0.98), or Output Gain when output clips but input is not hot. Never auto-boosts. Floor: 25% input (`minAutoInputVolume = minInputVolume`, same as the manual control) / 25% output gain. Logic lives in `SmartLevelController` (unit-tested); orchestration in `AudioModel.updateSmartLevel()`.
- **Warnings:** raw input peak before trim detects source/ADC clipping that software trim cannot repair; trimmed peak drives "Input too loud" and Smart Level input decisions.

## NoNoise Mic virtual driver (Tier 3, Spec A) — `Driver/`
- **What:** a userspace CoreAudio **AudioServerPlugIn** (`Driver/NoNoiseMic/NoNoiseMic.c`) that publishes a **visible input-only** device "NoNoise Mic" + a **hidden output-only** device "NoNoise Mic Engine". The app renders cleaned audio to the engine device; consumer apps pick "NoNoise Mic" as their microphone. Phase A1 = in-driver **loopback**; Phase A2 (gated) adds an XPC/shared-memory path.
- **Shared contract (a mismatch fails SILENTLY — keep C and Swift identical):** visible name `NoNoise Mic` / UID `NoNoiseMic:visible:48k2ch`; engine name `NoNoise Mic Engine` / UID `NoNoiseMic:engine:48k2ch`; bundle id `com.ivalsaraj.NoNoiseMic`; 48000 Hz, 2ch. Swift mirror: `Sources/Core/AudioProcessing/VirtualMicRouting.swift`.
- **Canonical layout (one layout, every layer):** Float32 **interleaved** stereo `[L,R,L,R…]`, ASBD flags `kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked` (NEVER `…IsNonInterleaved`), `mBytesPerFrame = 8`. `ioMainBuffer` is passed straight into `nn_ring` (`channels=2`) — no de/interleave anywhere.
- **`sourceMode` (`'srcm'`, FourCharCode `0x7372636D`):** `0` = loopback (A1 default), `1` = xpc (A2). Use the char literal `'srcm'` in C — never hand-type the hex (a transposed digit fails silently). Cross-process Set needs `kAudioObjectPropertyCustomPropertyInfoList` registration — deferred to A2; A1 only relies on the default `0`.
- **Topology + timing:** ONE shared loopback ring (`nn_ring`) + a per-device zero-timestamp clock (`nn_clock`), both anchored to a SINGLE host time captured on the first `StartIO`, so the engine's write axis and the mic's read axis coincide. The engine device returns `0` for `…CanBeDefaultDevice`/`…CanBeDefaultSystemDevice` and `1` for `kAudioDevicePropertyIsHidden`.
- **Ring serves SILENCE, never stale speech (privacy-critical):** `nn_ring` tracks a `writeEnd` watermark (published release / read acquire). `nn_ring_read_at` zeroes any frame at/after `writeEnd` (not yet produced) or older than one capacity (overwritten/wrapped) — so if the engine writer stops while the mic keeps running, the consumer app gets silence, NOT a modulo-aliased loop of the last ~1.3 s of cleaned audio. The mic-read `else` branch (`sourceMode==1`, A2-not-yet-wired) likewise `memset`s silence.
- **Pure testable math:** the only risky logic (wraparound + zero-timestamp + the silence window) lives in CoreAudio-free C (`Driver/NoNoiseMic/nn_ring.{c,h}`, `nn_clock.{c,h}`) and is host-unit-tested via `Driver/tests/run-tests.sh` (mirrors the repo's "keep DSP math in testable statics" rule) — including read-before-write, writer-stopped, and partial-straddle silence cases. `DoIOOperation` stays allocation/lock/syscall-free; `GetPropertyData` validates `inDataSize` on every scalar/CFString branch (a short buffer must never corrupt `coreaudiod`), and the stream format setter accepts ONLY the full canonical ASBD (rejecting non-interleaved/repacked layouts).
- **Signing rule:** ad-hoc sign the bundle **AFTER** full assembly; any post-sign edit invalidates the signature and the plug-in **silently fails to load**. `install-driver.sh` verifies the device actually appeared. Distinguish app Gatekeeper (right-click → Open) from driver load (coreaudiod signature check).
- **Licensing:** original implementation against the public API (MIT) — NOT Apple sample source, NOT derived from BlackHole (GPL-3.0).
- **App-side routing (`AudioModel.fetchOutputDevices`):** auto-routes the engine's output to the hidden "NoNoise Mic Engine" via `VirtualMicRouting.preferredOutputUID` (engine → BlackHole fallback → else leave unset; never auto-route to a physical output). Devices are matched by **real UID** (`kAudioDevicePropertyDeviceUID`), not name — only a UID translates to an `AudioObjectID`. **The hidden engine (`kAudioDevicePropertyIsHidden=1`) is EXCLUDED from `kAudioHardwarePropertyDevices` enumeration**, so it must be resolved by UID translate (`kAudioHardwarePropertyTranslateUIDToDevice`) and injected into the route set — the enumeration loop will never see it. (Same translate path resolves `driverInstalled` from the input-only visible mic.) The engine + any hidden device are filtered from the app's own pickers via `isSelectableOutput`, and "NoNoise Mic" is filtered from the input list to prevent a loopback echo.
- **On-demand capture (`AudioModel`, Krisp-like):** when the driver is installed, the app holds the **real mic** (and the macOS orange indicator) ONLY while some app is actually using "NoNoise Mic" — observed via a `kAudioDevicePropertyDeviceIsRunningSomewhere` listener on the visible mic. The render engine to the hidden sink stays warm; only the `AVCaptureSession` is gated. Without the driver (BlackHole fallback) there's no per-use signal, so capture stays always-on.

## Incoming / guest cleanup (clean the other side) — `IncomingCleanupEngine` (tap-based, macOS 14.4+)
- **What:** a SECOND, independent capture→clean→play pipeline that de-noises the audio the user *hears* (noisy guests/callers). It captures **all system audio EXCEPT NoNoise's own process** via a **Core Audio process tap** (`CATapDescription(stereoGlobalTapButExcludeProcesses:)` + a private aggregate device + an `AudioDeviceIOProcID`) — **no BlackHole, no loopback device, no manual routing**. It runs its OWN `DeepFilterNetDSP` (DFN only — **no** `VoiceChain`) and re-renders the cleaned result to the **current default output**, auto-following device changes. The tapped originals are **muted** (`desc.muteBehavior = .muted`), so the user hears only NoNoise's cleaned playback. It is **not** an `AudioModel` and never touches the mic path or the NoNoise Mic sink. **A SINGLE toggle** — no source/monitor pickers.
- **macOS 14.4+ only; the whole type is `@available(macOS 14.4, *)`.** 14.4 is the explicit product floor even though the underlying symbols are older (tap C API 14.2, `CATapDescription` init 14.0); we call the **C** `AudioHardwareCreateProcessTap` (NOT the macOS-15 `AudioHardwareTap` Swift overlay), and every tap call sits behind `#available(macOS 14.4, *)` so the package still compiles against its `.macOS(.v13)` deployment target. `AudioModel` stores the engine as `AnyObject?` so it needn't itself be gated; it only ever constructs/casts `IncomingCleanupEngine` inside `#available` blocks.
- **Two realtime threads bridged by a LOCK-FREE SPSC ring — never a locking `RingBuffer`.** The tap IOProc (producer, HAL realtime IO thread) and the `AVAudioSourceNode` render block (consumer, audio render thread) are BOTH realtime; a lock between them risks priority inversion / dropouts. They are bridged by `TapAudioRing` (Swift owner) over the C `tap_ring` (`Sources/CTapRing`) — a C11-atomics acquire/release SPSC float FIFO that mirrors the driver's tested `nn_ring` discipline (C target because `Atomic`/`Synchronization` need macOS 15). Both callbacks are **allocation/lock/syscall-free** and treat the HAL input buffers as **read-only**: the IOProc reads the tapped frames, does a `vDSP` N→mono downmix into a **pre-allocated** scratch, and writes the mono result to the ring; the render block drains the ring (latency-trim via `tap_ring_drop`), runs DFN in place, and fills silence on underflow.
- **Off by default + lazy lifecycle (zero-cost when off):** `AudioModel` holds it as an OPTIONAL (`AnyObject?`, never a stored `let`). `AudioModel.reconcileIncomingCleanup(desiredTarget:)` (called from `applyCleanupPlaybackRoute()`) CREATES it only on the enabled transition (supported OS + toggle on) and releases it to `nil` when disabled/unavailable. Rationale: `DeepFilterNetDSP.init()` allocates ML buffers + async-loads the CoreML model — it must NOT run at launch. Each fresh engine instance gets its OWN DeepFilterNet recurrent state (correct — a new stream starts clean).
- **`start() -> Bool` is truthful; the owner retains ONLY a genuinely-running engine.** Build order (composite of `prepareCapture()` + `startPlayback()` + `startIO()` — see the `.external` split below): resolve our own audio process object (**HARD-FAIL** if invalid — a global-exclude tap built around an unknown own-process id would exclude *nothing* and re-capture/mute our own cleaned playback) → create the muted tap → create the private aggregate (`tapautostart=true`, pinned to 48 kHz) → read the tap `AudioStreamBasicDescription` ONCE → create the IOProc → start the playback engine FIRST → `AudioDeviceStart` LAST (so the global mute only engages once our re-render is already playing). Any failure runs `stop()` and returns `false`. `AudioModel` assigns `incomingEngine` ONLY when the build succeeds (else `nil` + `.failed`).
- **`.external` playback route (VPIO-hook — see "Voice Processing I/O (VPIO)" below):** `IncomingCleanupEngine(playbackTarget: .external)` skips the playback graph/listeners entirely — `prepareCapture()` builds ONLY the tap+aggregate+IOProc (plus an `.external`-only default-output HEALTH listener, `checkExternalHealth()`, since this mode has no playback graph of its own to repin), `makeRenderHook()` exposes a `CleanupRenderHook` (raw ring/dsp pointers), and `startIO()` starts the aggregate's IO separately — so `AudioModel` can sequence "hand the hook to `VoiceIOEngine` and confirm it's rendering" BEFORE "start the tap's mute" (the mute-order invariant `CleanupRouteTransition.plan` encodes as `.attachHook` before `.startIO`).
- **Single idempotent teardown (`stop()`), MUST run on every failure path:** stop IO → destroy IOProc → destroy aggregate → destroy tap → remove the default-output HAL listener → remove the `AVAudioEngineConfigurationChange` observer → stop+reset the playback engine. Each handle is guarded + zeroed so a second call is a no-op. **A leaked *muted* tap keeps OTHER apps muted system-wide**, so teardown is mandatory on all paths (and on `deinit`).
- **Default-output follow (re-pin vs rebuild):** a `kAudioHardwarePropertyDefaultOutputDevice` HAL listener + an `AVAudioEngineConfigurationChange` observer (both on `.main`) call `repinPlayback()`, which **re-pins** the playback output unit to the new default (cheap, bumpless) UNLESS the tap/aggregate itself died (then full `stop()` + `start()`). The re-pin-vs-rebuild decision is the pure, unit-tested `IncomingTapLogic.repinDecision(tapAlive:)`. `repinToDefaultOutput()` is a no-op when the default hasn't changed (breaks the set-CurrentDevice → config-change → re-pin feedback cycle). `refreshDevicesAfterHardwareChange()` does **not** re-apply the engine (the tap captures all-system-minus-NoNoise and follows the default output itself).
- **Canonical effective status — never a lying toggle.** The UI binds to `AudioModel.incomingCleanupStatus` (`IncomingCleanupStatus`: `.unavailable` / `.off` / `.cleaning` / `.failed`), NOT the raw persisted flag, because `start()` can fail (TCC denied, own-process unresolved, tap/aggregate creation failed) and the owner then retains NO engine. `.unavailable` (OS < 14.4) disables the toggle; `.failed` keeps the toggle on so granting audio-capture permission + re-toggling retries. `isIncomingCleanupAvailable` = `#available(macOS 14.4, *)`.
- **DFN-only:** the incoming path runs DeepFilterNet **only** — no `VoiceChain`/Broadcast Voice (that polish is voice-shaping for the *outgoing* mic, inappropriate for arbitrary guest audio).
- **Pure, headless-tested logic** (kept OUT of the `@available` engine, mirroring the project's "risky logic in tested statics" rule): the own-process-object validity predicate (`IncomingTapLogic.isValidProcessObject`), the re-pin-vs-rebuild decision, and the lock-free ring's wrap/fill/drain/underflow/overflow math (`TapAudioRingTests`, `IncomingTapLogicTests`). The tap/aggregate/IOProc path itself is integration-only (needs a 14.4+ host + granted TCC) → manual smoke test.
- **TCC:** process taps require audio-capture consent. `Resources/Info.plist` carries **`NSAudioCaptureUsageDescription`** (a usage-description string, **not** a new entitlement — the two-entitlement policy still holds). There is no public API to pre-check/request it; the system prompt fires on first tap use.
- **Persistence:** only `mv.incomingEnabled` (off by default). The old `mv.incomingSourceUID` / `mv.incomingOutputUID` keys, the source/monitor pickers, `fetchIncomingDevices`, the `monitorOutput*`/`incomingSource*` maps, and `VirtualMicRouting.isSelectableIncomingSource`/`isSelectableMonitorOutput` + `DeviceInfo.hasInput`/`transportType` are **removed**. Re-applied via `applyCleanupPlaybackRoute()` after `loadSettings()`.

## Voice Processing I/O (VPIO) — `VoiceIOEngine`, `mv.voiceProcessing` (experimental, off by default)

- **What:** an app-side root fix for the built-in-speaker echo problem (see
  `docs/knowledge/knowledge1.md` 2026-09-01/09-02 entries): moves mic capture onto Apple **Voice
  Processing I/O** (`AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)`), whose echo canceller
  references audio THIS process plays through its own paired output bus. `IncomingCleanupEngine`/
  `SpeakerCleanupEngine` hook their cleaned re-render into that bus instead of their own
  `AVAudioEngine` — so Apple's AEC cancels NoNoise's own playback from the mic it's about to
  re-capture, fixing the speaker-echo case entirely on-device (no cloud AEC, no WebRTC dependency).
  A SECOND `MicCaptureBackend` alongside `AVCaptureMicBackend`; `AudioModel` falls back to
  `AVCaptureMicBackend` on ANY VPIO failure (never leaves capture dead).
- **Flag-gated, lazy, truthful:** `AudioModel.voiceProcessingEnabled` (`mv.voiceProcessing`, default
  **false**) is the only thing that constructs a `VoiceIOEngine` — `applyMicBackend()` is the sole
  construction site (verify with `grep VoiceIOEngine(` — exactly one call site). The UI binds to
  `AudioModel.voiceProcessingStatus` (`VoiceIOLogic.VoiceIOStatus`: `.off` / `.active` /
  `.fallback(FallbackReason)` / `.failed`), never the raw flag — a `.fallback` means `AudioModel` has
  already switched `currentBackend` back to `AVCaptureMicBackend`; the reason
  (`.startFailed` / `.inputPinFailed` / `.unsupportedInputRate` / `.runtimeRestartExhausted`) drives a
  differentiated Settings caption.
- **No output-device pin (real-hardware finding):** on real VPIO hardware, `inputNode.audioUnit` and
  `outputNode.audioUnit` are the SAME underlying duplex Audio Unit. Pinning the output side after the
  input pin silently OVERWRITES it, pointing the whole duplex unit at the output device (typically
  the built-in speaker, zero input channels) — capture goes dead. `VoiceIOEngine` pins ONLY the
  input; output simply follows the engine's own default output, and a default-output change is
  caught by the existing `installDefaultOutputListener()` → full rebuild.
- **Fixed mono/48 kHz tap, NO resampling.** `buildAndStart()` verifies `inputNode.outputFormat(forBus:
  0).sampleRate` is genuinely ~48 kHz BEFORE ever installing a tap; a non-48k bus (some BT headsets
  force VPIO to 16/24 kHz) abandons VPIO outright via `FallbackReason.unsupportedInputRate` rather
  than resampling — a BT headset is earphones, which have no acoustic loop to begin with, so the
  echo problem this feature targets is already structurally absent for it.
  `installTap` always uses the fixed `AudioUtils.shared.processingFormat` (mono/48 kHz), matching the
  proven `--aec-spike` harness exactly; `MicFormatNormalizer` only VALIDATES each buffer's format
  (never converts) and reports `onInvalidBuffer` (→ `onRuntimeFailure`) rather than silently dropping
  or mis-processing a malformed buffer.
- **Input device pin: uninit→set→init cycle, gated on manual selection.** Pinning
  `kAudioOutputUnitProperty_CurrentDevice` after `engine.prepare()` needs
  `AudioUnitUninitialize` → `AudioUnitSetProperty` → `AudioUnitInitialize` (a bare `Set` fails with
  -10849). Only attempted when `isManualDeviceSelection` is true (set by `AudioModel` from
  `inputDeviceSelection != .autoInputSelection`, NOT from the resolved UID string `configure(deviceUID:)`
  receives — that's always a concrete UID, never the literal "auto" sentinel, so comparing it to the
  sentinel would never actually skip the pin). A failed MANUAL pin surfaces
  `.fallback(.inputPinFailed)` and `AudioModel` ACTUALLY switches capture to `AVCaptureMicBackend`
  (not just the status label — a pin failure means VPIO would silently capture the wrong device).
- **Hook lifecycle — the ONLY hook-swap path is `restart(withHook:owner:)`.** `hookBox`
  (`UnsafeMutablePointer<CleanupRenderHook?>`) is written ONLY while the engine is stopped, so the
  realtime render callback never races a write. `owner: AnyObject?` is retained STRONGLY alongside
  the hook (`hookOwner`) for as long as it's wired — this keeps the hook-owning cleanup engine ALIVE
  even if `AudioModel` drops its own reference first, closing a use-after-free hazard. `detachHook()`
  (stop-if-running-then-clear, or clear-directly-if-already-stopped) is the mandatory first step
  before releasing any hook-owning engine — `AudioModel.releaseIncomingEngine()`/
  `releaseSpeakerEngine()` are the ONLY places `incomingEngine`/`speakerEngine` are set to `nil`, and
  both detach first.
- **Cleanup-engine route transitions are PLANNED, not hand-rolled.** `VoiceIOLogic.CleanupRouteTransition.plan(from:to:)`
  is the pure, headless-tested (see `VoiceIOLogicTests`) ordering: a hook is ALWAYS detached before
  its owning engine is stopped, and a NEW hook is ALWAYS confirmed attached (`.attachHook`) before
  the new engine's IO — and thus its tap mute — starts (`.startIO`). `AudioModel.executeCleanupRouteTransition`
  interprets this list against `IncomingCleanupEngine`/`SpeakerCleanupEngine` through one shared
  `CleanupEngineLifecycle` protocol (file-scope `private` in `AudioModel.swift`, conformances declared
  there too since it's an orchestration concern, not a property of the engines) — so both engines
  share ONE execution path instead of two hand-written, easy-to-desync copies. A route switch (or a
  fresh enable while VPIO is already active) builds DIRECTLY in the target mode — never
  `.ownEngine`-then-rebuild-to-`.external`.
- **Runtime health checks, both directions.** `VoiceIOEngine.scheduleRestart()` bails immediately if
  `engine.isRunning` (macOS can re-deliver a config-change/default-output notification for a change
  that never actually stopped it, or that a previous restart already fixed — without this guard every
  such self-induced callback resets the backoff, defeating it; mirrors the 2026-08-30 [GOTCHA] rule
  for the main playback engine). Conversely, a hook-owning (`.external`) cleanup engine installs its
  OWN default-output health listener (`checkExternalHealth()`, reusing `IncomingTapLogic.repinDecision`
  as a plain `tapAlive`→`.repin`/`.rebuild` check) since it has no playback graph of its own to repin;
  and `VoiceIOEngine.onRebuilt` fires after every successful rebuild so `AudioModel` can
  re-verify a hook-owning cleanup engine's capture side didn't die alongside it.
- **Persistence:** only `mv.voiceProcessing` (off by default, in `SettingsResetPolicy.resettableKeys`).
  Not part of `VoiceProfile` (device/hardware-dependent, not a "voice" setting).
