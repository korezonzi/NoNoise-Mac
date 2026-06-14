# Knowledge Log

`[GOTCHA]` / `[DECISION]` / `[PATTERN]` entries. Newest on top. See `critical-patterns.md`
for the must-read failure modes.

---

### [GOTCHA] 2026-06-15 — `allow-jit` entitlement is required for CoreML/Metal
- `Resources/NoNoiseMac.entitlements` carries two keys: `com.apple.security.device.audio-input`
  (mic) and `com.apple.security.cs.allow-jit`. The latter is needed because DeepFilterNet3 runs on
  GPU/ANE and Metal shader compilation JITs under the hardened runtime — removing it can break
  inference at runtime. It was inherited from the original app (kept byte-identical); justification
  now lives in `AGENTS.md` → Entitlements & signing. Do not strip it without on-device verification.

### [DECISION] 2026-06-15 — Docs must match the real CLI contract
- `NoNoiseMacCLI` with no `--in`/`--out` prints an error and exits 1; `--help` exits 0; device names
  are echoed only after a valid launch (`Sources/CLI/main.swift:21-23,30-34,42,51`). README must
  describe this exactly — a marketing page that advertises a non-existent mode erodes first-release
  trust. Caught by the pre-publish Codex code review.

### [DECISION] 2026-06-15 — AI noise cancellation defaults ON
- `AudioModel.isAIEnabled` defaults to `true` so suppression is active on first launch
  (product decision for NoNoise Mac). The Meeting preset remains the default profile.
- Implication: the model is exercised immediately; keep the CoreML init path healthy.

### [DECISION] 2026-06-15 — Rebrand to NoNoise Mac; internal `mv.*` keys kept
- Renamed display/identifier/bundle to NoNoise Mac / `NoNoiseMac` / `com.ivalsaraj.NoNoiseMac`.
- `UserDefaults` keys intentionally **kept** in the legacy `mv.*` namespace — invisible to
  users, renaming would only add migration risk. See `AGENTS.md` → Branding conventions.

### [GOTCHA] CoreML Float16 outputs read back as zeros on ANE/GPU
- See `critical-patterns.md`. Read model outputs via `NSNumber`, not raw Float16 buffers.

### [GOTCHA] Inventing a spectral compression exponent muffles speech
- Stock DeepFilterNet has none; do not add `c=0.5/0.6` or de-normalize the output.

### [PATTERN] Keep DSP math in pure, testable statics
- `minGain(forAttenuationDb:)`, `resolveOutputBin(...)`, and the `VoiceChain` value types
  (`Biquad`/`Compressor`/`Limiter`) are unit-tested without CoreML. New DSP math should
  follow the same shape (30 tests currently cover this).
