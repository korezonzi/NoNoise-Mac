# Agent Store — NoNoise Mac

A **documented catalog** of the AI agents we recommend running against this codebase. This
is a registry, not executable agent definitions — each entry describes *when* to invoke an
agent, *what* to give it, *what* it returns, and the *guardrails* it must respect. Pair it
with [`../../AGENTS.md`](../../AGENTS.md) (invariants) and
[`../knowledge/INDEX.md`](../knowledge/INDEX.md) (memory).

> Convention: invoke the agent best matched to your task. Every agent MUST read
> `AGENTS.md` and `docs/knowledge/critical-patterns.md` before changing audio code.

---

## 1. DSP Invariant Guardian
- **Use when:** changing anything under `Sources/Core/AudioProcessing/` (feature pipeline,
  STFT/ISTFT, model call, blend).
- **Inputs:** the diff + `AGENTS.md` (DSP invariants) + `critical-patterns.md`.
- **Outputs:** pass/fail against each invariant (wnorm scale, no compression exponent, no
  output de-normalization, model input/feature math), with line-anchored findings.
- **Guardrails:** never weaken an invariant to make a test pass; behavior must stay
  byte-for-byte in the default path.

## 2. CoreML I/O Boundary Auditor
- **Use when:** touching the model prediction call or hidden-state bridging.
- **Inputs:** the model-call code region.
- **Outputs:** confirmation that **outputs** are read via `NSNumber` and only **our**
  input arrays use raw buffer pointers; flags any `withUnsafeBufferPointer(ofType: Float16…)`
  on a model output.
- **Guardrails:** zero tolerance — this failure ships as total silence.

## 3. Real-Time Safety Reviewer
- **Use when:** editing `processHop`, the render callback, or `VoiceChain.process`.
- **Inputs:** the diff.
- **Outputs:** list of any heap allocations / Array COW / locks introduced on the render
  thread; confirms scratch is pre-allocated and mutated in place.
- **Guardrails:** coefficient recompute stays on main; state persists across buffers.

## 4. Preset & Knob Consistency Checker
- **Use when:** changing `VoicePreset`, suppression knobs, or persistence.
- **Inputs:** `VoicePreset`, `AudioModel` preset wiring, tests.
- **Outputs:** verifies `VoicePreset.maxAttenuationDb == DeepFilterNetDSP.maxAttenuationLimitDb`,
  the `isApplyingPreset` guard is intact, and `.custom` flip/persist behavior holds.

## 5. Release & Bundle Agent
- **Use when:** cutting a build/release.
- **Inputs:** clean working tree.
- **Outputs:** runs `swift build -c release` + `./bundle.sh`; verifies `NoNoiseMac.app`
  layout, codesign + entitlements, and that the `.mlmodelc` is bundled.
- **Guardrails:** never commit `NoNoiseMac.app` / binaries (see `.gitignore`).

## 6. Branding / Rebrand Auditor
- **Use when:** before any commit, and after large refactors.
- **Inputs:** the tree.
- **Outputs:** runs `rg -i 'metalvoice|ghostkwebb'` and confirms matches exist **only** in
  the provenance allowlist (`README.md`, `LICENSE`, `AGENTS.md`, `docs/`); flags leaks in
  `Sources/`, `Package.swift`, `Resources/`, `bundle.sh`, `CONCEPTS.md`, `CONTRIBUTING.md`,
  `.github/`.

## 7. Audio Pipeline Explainer (onboarding)
- **Use when:** a new contributor/agent needs the mental model.
- **Inputs:** `AGENTS.md`, `CONCEPTS.md`, `Sources/Core`.
- **Outputs:** a capture → ring buffer → DSP → voice polish → output walkthrough with the
  key invariants and where each lives.
