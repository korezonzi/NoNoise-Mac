# VPIO (AEC) HITL Test Matrix

> Phase 3 deliverable of the speaker-echo root fix (see `docs/knowledge/knowledge1.md`
> [DECISION] 2026-09-02 for the spike results this builds on). Fill the result cells with
> ✅ / ⚠️(notes) / ❌(notes) + date. Every row assumes the `mv.voiceProcessing` flag ON
> unless the row says otherwise.

## How to read a row

- **Mic / Output**: physical devices in use. "BT" = Bluetooth (AirPods or headset).
- **Cleanup**: the receive-cleanup mode — `off` / `speaker` (NoNoise Speaker virtual
  device) / `allSystem` (process tap).
- **App**: the calling app on the OTHER side of the loop. The far-end participant reports
  whether they hear themselves (echo), and the local user reports voice quality.

## Priority 1 — the shipping scenario (must all pass before Phase 4)

| # | Mic | Output | Cleanup | App | What to verify | Result |
|---|-----|--------|---------|-----|----------------|--------|
| 1 | built-in | built-in speaker | allSystem | Meet | Far end hears NO echo of themselves (the original bug). Local user hears cleaned guest audio. | |
| 2 | built-in | built-in speaker | speaker | Meet | Same as #1 via the NoNoise Speaker route. | |
| 3 | built-in | built-in speaker | off | Meet | No regression: the call app's own AEC still works (this case was healthy pre-fix). | |
| 4 | built-in | built-in speaker | allSystem | Zoom | Same as #1 on Zoom. | |
| 5 | built-in | earphones (wired) | allSystem | Meet | Earphone regression guard: no quality change vs pre-fix. | |
| 6 | flag OFF (any) | any | any | Meet | Rollback path: toggling the beta flag OFF restores pre-fix behavior without restart. | |

## Priority 2 — device churn & fallback

| # | Scenario | What to verify | Result |
|---|----------|----------------|--------|
| 7 | Default output switch mid-call (built-in → AirPods → built-in) | VPIO restarts, audio resumes within ~1–2 s, no stuck mute (tap teardown intact). | |
| 8 | BT mic + built-in speaker (mismatched pair) | Either works, or falls back to AVCapture with the Settings caption showing "従来方式で動作中" — never silent failure. | |
| 9 | Unplug the manual-selected mic mid-call | Existing orange "いま: <mic>" caption + capture continues on fallback device. | |
| 10 | Cleanup toggle mid-call (off→on→off) | Blip ≤ ~100 ms, no residual mute of other apps after off. | |
| 11 | Long call (30+ min, speakers, cleanup on) | No drift/echo creep, no tap zero-fill (known process-tap decay bug), CPU stable. | |

## Priority 3 — quality / naturalness (Phase 3 tuning inputs)

| # | Scenario | What to verify | Result |
|---|----------|----------------|--------|
| 12 | `--aec-spike agc` (30 s speech ×2, listen to the 4 WAVs) | AGC-off keeps levels natural; Apple NS + DFN double-processing does not sound over-suppressed/choppy. | |
| 13 | Double-talk on speakers (both sides talk at once) | Far end still hears the local voice (no hard gating dropouts). | |
| 14 | Music playing locally during a speaker call, cleanup off | Ducking side effect: how much does macOS duck the music? Annoyance level. | |
| 15 | Auto preset (`自動`) + VPIO | AutoStrengthController behaves (AEC'd input changes the noise profile DFN sees). | |

## Recording results

Append findings (with dates and device/OS details) to `docs/knowledge/knowledge1.md` as
[GOTCHA]/[DECISION] entries — especially any row that fails or needs a tuning change.
