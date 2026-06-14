# Critical Patterns — read before touching audio code

These are **shipped-and-broke** failure modes. Each cost real debugging time. Treat them as
hard rules; the full rationale is in `AGENTS.md`.

## [PATTERN] CoreML output arrays MUST be read via `NSNumber`, never raw Float16 pointers
- **Where:** `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift` (the model-call boundary).
- **Symptom:** App produces **no audio** when AI is enabled (silent output).
- **Root cause:** The model runs `computeUnits = .all` (ANE/GPU). Reading its Float16
  output `MLMultiArray`s with `withUnsafeBufferPointer(ofType: Float16.self)` reads back
  **zeros** (the buffer isn't CPU-materialized).
- **Rule:** Read model **outputs** via the `NSNumber` subscript
  (`enhanced[[...] as [NSNumber]].floatValue`). Buffer pointers are only safe for **input**
  arrays we allocate and fill ourselves.

## [PATTERN] No spectral compression exponent; do not de-normalize the output
- **Where:** DFN feature pipeline + ISTFT in `DeepFilterNetDSP`.
- **Symptom:** Muffled, dull voice; attenuated highs.
- **Root cause:** A prior reimplementation invented a compression exponent (`c=0.5/0.6`) and
  de-normalized the enhanced spectrum. Stock DeepFilterNet does neither.
- **Rule:** Feed `spec` raw (`wnorm·FFT(window·x)`, `wnorm=1/960`); ISTFT the enhanced spec
  directly in the same scale. No compression, no output de-normalization.

## [PATTERN] The render thread is allocation-free
- **Where:** `processHop` / render callback (`DeepFilterNetDSP`, `AudioModel`, `VoiceChain`).
- **Symptom:** Audio glitches / dropouts under load.
- **Root cause:** Heap allocation (incl. Swift Array COW on first mutation through a local
  binding) on the real-time thread.
- **Rule:** Pre-allocate all scratch + input `MLMultiArray`s in `init()` and mutate the
  stored properties **directly**. Feature history uses `SpecHistoryRingBuffer`, never
  `Array.removeFirst`. Coefficient recompute (`VoiceChain.configure`) happens on main only.

## [PATTERN] Suppression knobs are lock-free scalars (arm64)
- **Where:** `DeepFilterNetDSP.suppressionStrength` / `attenuationLimitDb` / `outputGain`.
- **Rule:** Plain `var Float`, written from main, read on the render thread. 32-bit aligned
  scalar load/store is atomic on arm64 — **do not add locks**. Keep blend math in the pure
  static helpers (`minGain`, `resolveOutputBin`) so it stays unit-testable without CoreML.
