# 0001 — Rebrand to NoNoise Mac (decision record)

**Date:** 2026-06-15 · **Status:** Implemented (v1.0.0)

## Context
This project began as **MetalVoice** by Ghostkwebb
(https://github.com/Ghostkwebb/MetalVoice, MIT) — a real-time, on-device macOS noise
suppressor built on DeepFilterNet3 + CoreML. This release rebrands it to **NoNoise Mac**,
makes the repository AI-native, and polishes the UX, **without changing audio behavior**.

## Decisions
1. **Naming.** Display name **NoNoise Mac**; code identifier **NoNoiseMac** (executable,
   SwiftPM package + targets, class prefix, asset filenames); bundle id
   **com.ivalsaraj.NoNoiseMac**; CLI **NoNoiseMacCLI**.
2. **Versioning.** Reset to **1.0.0** (build 1) — new brand's first public release.
3. **AI on by default.** `AudioModel.isAIEnabled = true` so suppression is active on first
   launch (Meeting preset remains the default profile).
4. **UI polish.** Menu-bar popover and Settings reworked with a consistent card system,
   hero status, live meter, branded headers. View-layer only — bindings unchanged.
5. **AI-native repo.** Added `AGENTS.md` (overview + ICP + architecture + invariants +
   branding conventions), `CONCEPTS.md`, a knowledge base (`docs/knowledge/`), an agent
   catalog (`docs/agents/README.md`), `CONTRIBUTING.md`, and CI.
6. **Licensing & credit.** MIT retained; original copyright kept and new holder added;
   README credits DeepFilterNet and the original MetalVoice project.
7. **History.** Published as a single first commit (no prior history); build artifacts and
   scratch files excluded.

## Non-goals
No DSP/model/audio-pipeline changes; no logo redesign (existing text-free art reused);
no Intel support; no behavioral change to presets/knobs.

## Verification
`swift build`, `swift build -c release`, and `swift test` (30 tests) all pass; `./bundle.sh`
produces `NoNoiseMac.app` + `NoNoiseMacCLI`; brand/cruft scans clean (allowlist only).

## Post-Implementation Amendments
Pre-publish Codex code review (gpt-5.5, approved round 2) surfaced two **plan gaps** (not
implementation errors) — the plan didn't call out doc-vs-runtime accuracy or entitlement
provenance:
1. **README CLI accuracy.** The marketing README must describe the *actual* `NoNoiseMacCLI`
   contract. Fixed: documented `--help`; removed a non-existent no-arg "list devices" mode.
   Root cause: the plan treated the README as pure marketing without a doc-vs-code check.
2. **Entitlements provenance.** `allow-jit` (inherited, required for CoreML/Metal JIT) was
   undocumented. Fixed: added `AGENTS.md` → Entitlements & signing; entitlement file left
   byte-identical to the original to avoid runtime regressions. Root cause: the plan's
   "no over-broad entitlements added" rule didn't require documenting inherited ones.
