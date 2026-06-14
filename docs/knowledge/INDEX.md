# Knowledge Base — Index

Compounding engineering memory for NoNoise Mac. Agents: **read before** working in a
documented area; **append** new gotchas/decisions after solving a non-obvious problem.

## How to use
- Starting work near the model call or render thread → read `critical-patterns.md` first.
- Look up a past gotcha/decision → `knowledge1.md`.
- See what changed and when → `timeline1.md`.
- Need domain vocabulary → `../../CONCEPTS.md`.
- Need architecture/build/test or invariants → `../../AGENTS.md`.

## Active documents
| File | Contents |
|---|---|
| [`critical-patterns.md`](critical-patterns.md) | Must-read, shipped-and-broke failure modes (CoreML I/O dtype boundary, no spectral compression, render-thread allocation). |
| [`knowledge1.md`](knowledge1.md) | `[GOTCHA]` / `[DECISION]` log. |
| [`timeline1.md`](timeline1.md) | Chronological changelog of notable changes. |

## Writing conventions
- Prefix entries with `[GOTCHA]`, `[DECISION]`, or `[PATTERN]` + a date (YYYY-MM-DD).
- State the symptom, the root cause, and the rule that prevents regression.
- Keep entries short; link to code paths (e.g. `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`).
