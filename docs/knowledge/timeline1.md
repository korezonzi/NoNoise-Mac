# Timeline

Chronological log of notable changes. Newest on top.

### 2026-06-15 — NoNoise Mac v1.0.0 (initial public release)
- Rebranded the project from **MetalVoice** (by Ghostkwebb,
  https://github.com/Ghostkwebb/MetalVoice, MIT) to **NoNoise Mac**: identifiers, bundle id
  `com.ivalsaraj.NoNoiseMac`, assets, CLI (`NoNoiseMacCLI`), and all UI strings.
- Made the repo **AI-native**: this knowledge base, `CONCEPTS.md`, the agent catalog
  (`docs/agents/README.md`), an expanded `AGENTS.md` (overview + ICP + architecture +
  branding conventions), and CI.
- **UI overhaul**: polished menu-bar popover (hero status card, live meter, sectioned
  cards) and Settings (branded header, consistent cards).
- **AI noise cancellation ON by default.**
- DSP/model/audio behavior unchanged. `swift build` + 30 tests green; `swift build -c release`
  + `./bundle.sh` produce a signed `NoNoiseMac.app` + `NoNoiseMacCLI`.
- **Pre-publish Codex code review** (gpt-5.5, 2 rounds → APPROVED): fixed the README CLI section
  to match real `NoNoiseMacCLI` behavior (documented `--help`; removed a non-existent no-arg
  "list devices" mode), and documented the two signing entitlements in `AGENTS.md`.

### Pre-rebrand (inherited from MetalVoice history)
- Voice Polish chain (Biquad/Compressor/Limiter + per-preset profiles + master toggle).
- Preset modes (Meeting/Podcast/Tutorial/Custom) + suppression-strength & reduction-limit knobs.
- DSP correctness fixes: read CoreML outputs via `NSNumber`; match DeepFilterNet feature
  pipeline (no invented compression); stride-aware spectrum reads.
