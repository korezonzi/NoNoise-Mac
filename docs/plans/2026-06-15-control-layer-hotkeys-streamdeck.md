# Control Layer: Global Hotkeys + A/B Bypass + Stream Deck

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **control layer** on top of `AudioModel` that exposes every user-facing action
(toggle AI, A/B bypass, cycle preset, cycle Broadcast Voice level, nudge output gain) as:
1. Typed Swift methods on a new `ActionDispatcher` coordinator.
2. System-wide hotkeys (Carbon `RegisterEventHotKey`), user-configurable and persisted under
   `mv.*`, with a settings UI to view and rebind.
3. A **custom URL scheme** (`nonoisemac://`) registered in `Info.plist` and handled in the app,
   so Stream Deck "Website/Open" (or `open nonoisemac://…`) can fire each action.
4. Extended `NoNoiseMacCLI` with discrete action verbs (`toggle`, `bypass`, `preset-next`, etc.)
   as a secondary scripting path.

**Architecture:** The control layer is split across two targets so it stays unit-testable:

- **`Sources/Core/ControlLayer.swift`** holds the PURE, framework-free models — the
  `ControlAction` enum (with its `nonoisemac://` URL + CLI parsers and gain constants), the
  `HotkeyActionID` enum, the `HotkeyBinding` model, and a pure `ControlReducer` seam that
  describes the state transitions WITHOUT touching `AudioModel`. The test target depends only
  on `Core` (`@testable import Core`), so these models MUST live in `Core` to be testable. They
  import nothing beyond `Foundation` — `HotkeyBinding` stores a plain `UInt32` modifier mask, NOT
  `NSEvent.ModifierFlags`.
- **`Sources/App/ActionDispatcher.swift`** holds the `ActionDispatcher` coordinator that adapts
  the pure reducer onto a live `AudioModel`. It sits between `AudioModel` (the Core state machine)
  and all external triggers.
- **`Sources/App/HotkeyManager.swift`** holds the Carbon / AppKit registration layer. This is the
  ONLY place `Carbon`, `AppKit`, and `NSEvent.ModifierFlags` appear; it adapts the pure `UInt32`
  modifier mask at the App boundary.

`AudioModel` itself gains **no knowledge** of hotkeys or URL schemes — all that wiring lives in
App. The Core target stays free of `Carbon` / `AppKit`-specific imports and fully unit-testable.

> **Why not a new SwiftPM target?** The existing `Core` target is already imported by both
> `NoNoiseMac` and the test target, and it is framework-free at the Swift level for these models
> (it links AVFoundation/CoreML, but the new file imports only `Foundation`). Adding the pure
> models to `Core` is the minimal change — no `Package.swift` edit is required. A separate
> `ControlCore` library target was considered and rejected as unnecessary indirection.

**Tech Stack:** Swift 5.9, SwiftUI, Carbon (`RegisterEventHotKey`), AppKit (`NSApp`,
`NSApplicationDelegate`), Swift Package Manager, XCTest.

**Execution location:** All commands run from the package root — the directory that contains
`Package.swift`. All paths are repo-relative.

---

## Context

### Why these specific features

`AudioModel` already owns all the hot-path knobs: `isAIEnabled`, `selectedPreset`,
`voicePolishEnabled`, `clarityLevel`, `outputGainValue`, `suppressionStrength`. They are
`@Published` and guarded by `isApplyingPreset`. They are safe to write from the main thread
while the render callback reads them on a background thread (arm64 scalar stores are atomic;
the `isApplyingPreset` flag is the only multi-step guard and is only used from main).

Power users — streamers, podcasters, online educators — need **hardware-backed controls** (a
dedicated hotkey or a physical Stream Deck button) that work while they are focused in another
app. The menu-bar popover requires clicking the menu-bar icon; that is too slow during a live
stream.

### Actions surface (all dispatched through `ActionDispatcher`)

| Action ID | What it does | Notes |
|---|---|---|
| `toggleAI` | Flip `isAIEnabled` | Safe to fire from background (see below) |
| `bypass` | Momentary or toggle passthrough | A/B bypass; see design |
| `presetNext` | Cycle `selectedPreset` forward | Wraps around |
| `presetPrev` | Cycle `selectedPreset` backward | Wraps around |
| `clarityNext` | Cycle `clarityLevel` forward | Wraps at `.high` → `.off` |
| `gainUp` | `outputGainValue += 0.1` (clamped to 4.0) | Matches the Settings slider range |
| `gainDown` | `outputGainValue -= 0.1` (clamped to 0.5) | Matches the Settings slider range |

> **Gain bounds:** The Settings → General "Output Gain" slider is `0.5...4.0`
> (`SettingsView.swift` `gainCard`). The hotkey/URL gain nudge MUST clamp to the SAME range —
> `gainMin = 0.5`, `gainMax = 4.0` — so a nudged value never lands outside what the slider can
> represent.

**Safety from a backgrounded global hotkey or URL open:** All these writes go to
`AudioModel`'s `@Published` properties on the main thread. `ActionDispatcher` is `@MainActor`,
so every `dispatch(_:)` runs on the main actor; the Carbon C callback (off the actor) hops via
`Task { @MainActor in … }` before calling the dispatcher, and SwiftUI `onOpenURL` / the
`@MainActor`-isolated `AppDelegate.application(_:open:)` are already on the main thread. The
render callback reads plain `Float`/`Bool` scalars (lock-free on arm64) or checks `isAIEnabled`
inside the audio thread — exactly the existing pattern for `outputGain` etc. No additional
synchronization is needed.

### A/B bypass design — desired vs. effective AI state

The naïve approach (save `isAIEnabled` on bypass entry, restore on exit) has a state hole:
if the user fires **toggle-AI while bypassed**, that toggle must change what AI will be AFTER
bypass — not flip the live `AudioModel.isAIEnabled` (which is forced `false` during bypass) and
then get clobbered on bypass exit.

The fix is a single canonical **desired** AI state separate from the **effective** state pushed
to `AudioModel`:

- `desiredAIEnabled: Bool` — the user's intended AI on/off, ignoring bypass. This is the value
  that `.toggleAI` flips, ALWAYS, whether or not bypass is active.
- **Effective** = `desiredAIEnabled && !effectiveBypass`. This is what gets written to
  `AudioModel.isAIEnabled`.
- `effectiveBypass = isBypassedMomentary || isBypassedToggle`.

`desiredAIEnabled` is seeded from `AudioModel.isAIEnabled` when the dispatcher is created, and is
kept in sync whenever `.toggleAI` fires. While bypassed, `.toggleAI` updates `desiredAIEnabled`
but keeps `AudioModel.isAIEnabled = false`; on bypass exit, the effective state is recomputed and
`desiredAIEnabled` is restored. Bypass state is session-only (never persisted); `desiredAIEnabled`
mirrors the persisted `isAIEnabled` preference, so the persisted value is correct after bypass exit.

Two gestures:
- **Momentary (hold):** Hotkey down → bypass on; hotkey up → bypass off. Carbon supplies
  separate `EventHotKeyPressed` / `EventHotKeyReleased` events. The default bypass key is
  mapped to the momentary path.
- **Toggle:** One additional `bypassToggle` action ID. Both can be hotkey-bound.

`isBypassedMomentary` and `isBypassedToggle` are tracked separately so a momentary hold and a
latched toggle can overlap without one cancelling the other; effective bypass = OR of the two.

### Global hotkey API choice: Carbon `RegisterEventHotKey`

**Chosen API: Carbon `RegisterEventHotKey` / `InstallEventHandler`.**

Rationale:
- Works system-wide from a backgrounded menu-bar app (`LSUIElement`) with **no additional
  entitlements or permissions** — specifically, no `com.apple.security.automation.apple-events`
  and no Accessibility permission prompt.
- `NSEvent.addGlobalMonitorForEvents(matching:)` is the SwiftUI-friendly alternative but
  **requires Accessibility permission** (the "NoNoise Mac would like to monitor keyboard input"
  prompt). That adds a second permissions friction point, and CLAUDE.md demands entitlements
  remain minimal. It is therefore **not used**.
- Carbon hotkeys are registered per-combo, not per-event-stream, which means only the
  combos we register ever fire our handler — no ambient keyboard snooping, better for privacy.
- The Carbon `EventHotKeyID` + `InstallEventHandler` pattern is well-supported on Apple
  Silicon macOS 13+ and is used by many menu-bar utilities (1Password, Raycast, etc.).

**Entitlement impact:** None. `RegisterEventHotKey` works under the hardened runtime with the
current two entitlements (`audio-input` + `allow-jit`). No new entitlement key is needed.

**Permission prompt:** None. Carbon hotkeys do not trigger an Accessibility prompt.

**Limitation:** If another app has already registered the same combo, `RegisterEventHotKey`
returns `eventHotKeyExistsErr` (-9878). `HotkeyManager` must handle this gracefully — log,
surface a UI warning ("hotkey in use"), and leave that slot unregistered without crashing.

### URL scheme design (Stream Deck path)

Custom URL scheme `nonoisemac://` registered in `Info.plist` (`CFBundleURLTypes`). No new
entitlement is needed for a custom URL scheme — it is a standard `Info.plist` registration.

Verbs map to action IDs:

| URL | Action |
|---|---|
| `nonoisemac://toggle` | `toggleAI` |
| `nonoisemac://bypass` | `bypassToggle` |
| `nonoisemac://preset/next` | `presetNext` |
| `nonoisemac://preset/prev` | `presetPrev` |
| `nonoisemac://clarity/next` | `clarityNext` |
| `nonoisemac://gain/up` | `gainUp` |
| `nonoisemac://gain/down` | `gainDown` |

**Stream Deck setup (documented):** Stream Deck "Open" action → URL → `nonoisemac://toggle`.
No Stream Deck SDK, no Stream Deck plugin, no developer account required. Works with Stream
Deck 6.x+ "Website" action in "Open in browser" mode (macOS opens the URL scheme registered
in `Info.plist`).

**URL-scheme registration in a SwiftPM `.app` bundle:** `Info.plist` is already in
`Resources/`, which `bundle.sh` copies into the `.app` bundle during signing. The
`CFBundleURLTypes` array is added to `Resources/Info.plist`. SwiftPM debug builds do NOT
register URL schemes (no bundle registration in the Swift package runner). URL-scheme handling
is only testable in the bundled `.app` (via `./bundle.sh` or `./install-app.sh`). This is
documented explicitly in Task 6 and the smoke-test section.

**`NSApplicationDelegate.application(_:open:)` vs `open urls:`:** On macOS 13+ with
`MenuBarExtra`-based apps (`@main struct … : App`), URL-scheme delivery goes through the
SwiftUI `App.onOpenURL` modifier, NOT through `NSApplicationDelegate`. Both are handled —
`NoNoiseMacApp` wires `onOpenURL` on the scene, and `AppDelegate` provides a fallback
`application(_:open:)` implementation. The `ActionDispatcher` is passed by reference from
`@StateObject` so both paths route to the same instance.

### `NoNoiseMacCLI` action verbs

`NoNoiseMacCLI` is a headless pipeline that initialises `AudioModel`. It can also emit
one-shot action commands using `--action <verb>` (starts model, fires the action, then
exits). Since `AudioModel.init()` is asynchronous (device setup), the existing 1-second
`RunLoop.main.run(until:…)` settle is reused.

---

## Current code facts (verified against the repo)

- `Sources/Core/AudioModel.swift`: `isAIEnabled`, `selectedPreset`, `voicePolishEnabled`,
  `clarityLevel` (added by the broadcast-voice plan), `outputGainValue` are `@Published` +
  `didSet`, guarded by `isApplyingPreset`. `PrefKey` enum lives at lines ~114–121. All
  written from main; render thread reads via lock-free arm64 scalars.
- `Sources/App/NoNoiseMacApp.swift`: `@main`, `@StateObject var audioModel = AudioModel()`,
  `@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate`. `AppDelegate` has
  `applicationDidFinishLaunching` only.
- `Sources/App/ContentView.swift`: `modeCard` uses a segmented `Picker` bound to
  `$audioModel.selectedPreset`. Cards use `nnCard()`.
- `Sources/CLI/main.swift`: simple flag parser; sets `model.selectedInputDeviceID`,
  `model.selectedOutputDeviceID`, `model.outputGainValue`, `model.isAIEnabled = true`.
- `Resources/Info.plist`: `LSUIElement = true`, `CFBundleIdentifier = com.ivalsaraj.NoNoiseMac`.
  No `CFBundleURLTypes` yet.
- `Resources/NoNoiseMac.entitlements`: exactly two keys (`audio-input`, `allow-jit`).
- `Package.swift`: `Core` target, `NoNoiseMac` app target, `NoNoiseMacCLI` executable,
  `NoNoiseMacTests` test target. Swift tools version 5.9, macOS 13+. The test target depends on
  **`Core` only** — it does NOT depend on `NoNoiseMac` (the app target). Anything tested must be
  reachable from `@testable import Core`.
- `Tests/NoNoiseMacTests/`: headless, no CoreAudio/CoreML. `@testable import Core`.
- `VoicePreset`: `String, CaseIterable, Identifiable, Sendable` in `Sources/Core/VoicePreset.swift`;
  cases can be cycled via `allCases` index arithmetic.
- `ClarityLevel`: `String, CaseIterable, Identifiable, Sendable` in
  `Sources/Core/AudioProcessing/VoiceChain.swift`; same cycling pattern (added by broadcast-voice plan).
- `Sources/App/ContentView.swift`: `ContentView(audioModel:)`; the gear button and the footer
  button both call `WindowManager.openSettings(model:)`. `WindowManager` (an `NSWindow` coordinator)
  and `SettingsView(audioModel:)` both live here / in `SettingsView.swift`.
- `Sources/App/SettingsView.swift`: `SettingsView(audioModel:)` hosts a `TabView` with two tabs
  (`GeneralSettingsView`, `GuideView`). The "Output Gain" slider range is **`0.5...4.0`** — the
  canonical gain range the hotkey nudge must match.

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch**

```bash
git checkout -b feat/control-layer-hotkeys-streamdeck
```

Expected: `Switched to a new branch 'feat/control-layer-hotkeys-streamdeck'`. Use
`git add <specific files>` in every commit — never `git add -A` or `.`.

---

## Task 1: Pure control models + reducer in `Core` — unit-testable core — TDD

Define the typed action enum, the persisted hotkey-binding model, the action-ID enum, and a
**pure state reducer** (`ControlReducer`) that describes every state transition WITHOUT touching
`AudioModel`. All of this is framework-free (imports only `Foundation`) and lives in `Core` so the
test target (`@testable import Core`) can exercise it directly. The Carbon/AppKit `HotkeyManager`
(Task 2) and the live `ActionDispatcher` adapter (Task 3) build on top of these models.

**Files:**
- Create: `Sources/Core/ControlLayer.swift`
- Create: `Tests/NoNoiseMacTests/ControlLayerTests.swift`

> **Why a reducer seam?** `AudioModel.init()` starts CoreAudio/AVFoundation, so it is NOT
> headless-testable (same constraint as the existing preset/DSP tests). To test the REAL dispatch
> logic — bypass transitions, the desired-vs-effective AI rule, hotkey→action mapping, gain
> clamping, preset/clarity cycling, and rebind persistence — without constructing `AudioModel`, the
> mutations are expressed as a pure function over a value-type `ControlState` snapshot. The App-side
> `ActionDispatcher` (Task 3) is a thin adapter: read state from `AudioModel` → run the reducer →
> write the resulting state back. No test-only branches exist in production code; the reducer is the
> production code path, exercised directly by tests and re-used verbatim by the adapter.

### Step 1: Write the failing tests

Create `Tests/NoNoiseMacTests/ControlLayerTests.swift`:

```swift
import XCTest
@testable import Core

/// Tests the PURE control layer: ControlAction parsers, HotkeyBinding persistence,
/// HotkeyActionID defaults, and the ControlReducer state machine (incl. A/B bypass
/// desired-vs-effective AI state). None of this touches AudioModel, so it runs headless.
final class ControlLayerTests: XCTestCase {

    // MARK: - URL parsing

    func testToggleURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://toggle")!), .toggleAI)
    }

    func testBypassURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://bypass")!), .bypassToggle)
    }

    func testPresetNextURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://preset/next")!), .presetNext)
    }

    func testPresetPrevURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://preset/prev")!), .presetPrev)
    }

    func testClarityNextURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://clarity/next")!), .clarityNext)
    }

    func testGainUpURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://gain/up")!), .gainUp)
    }

    func testGainDownURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://gain/down")!), .gainDown)
    }

    func testUnknownURLReturnsNil() {
        XCTAssertNil(ControlAction.from(url: URL(string: "nonoisemac://unknown/verb")!))
    }

    func testWrongSchemeReturnsNil() {
        XCTAssertNil(ControlAction.from(url: URL(string: "https://example.com/toggle")!))
    }

    // MARK: - CLI verb parsing

    func testCLIVerbToggle()       { XCTAssertEqual(ControlAction.from(cliVerb: "toggle"), .toggleAI) }
    func testCLIVerbBypass()       { XCTAssertEqual(ControlAction.from(cliVerb: "bypass"), .bypassToggle) }
    func testCLIVerbPresetNext()   { XCTAssertEqual(ControlAction.from(cliVerb: "preset-next"), .presetNext) }
    func testCLIVerbPresetPrev()   { XCTAssertEqual(ControlAction.from(cliVerb: "preset-prev"), .presetPrev) }
    func testCLIVerbClarityNext()  { XCTAssertEqual(ControlAction.from(cliVerb: "clarity-next"), .clarityNext) }
    func testCLIVerbGainUp()       { XCTAssertEqual(ControlAction.from(cliVerb: "gain-up"), .gainUp) }
    func testCLIVerbGainDown()     { XCTAssertEqual(ControlAction.from(cliVerb: "gain-down"), .gainDown) }
    func testCLIVerbUnknownNil()   { XCTAssertNil(ControlAction.from(cliVerb: "explode")) }

    // MARK: - Gain clamping constants (must match the Settings slider range 0.5...4.0)

    func testGainStepIsPositive() {
        XCTAssertGreaterThan(ControlAction.gainStep, 0)
    }

    func testGainBoundsMatchSlider() {
        XCTAssertEqual(ControlAction.gainMin, 0.5)
        XCTAssertEqual(ControlAction.gainMax, 4.0)
    }

    // MARK: - HotkeyBinding (pure model, plain UInt32 modifier mask)

    /// A binding round-trips through its UserDefaults string representation.
    func testHotkeyBindingRoundTrip() {
        let b = HotkeyBinding(keyCode: 0x00, modifiers: HotkeyModifier.command.rawValue | HotkeyModifier.shift.rawValue)
        let decoded = HotkeyBinding(encoded: b.encoded)
        XCTAssertEqual(decoded?.keyCode, b.keyCode)
        XCTAssertEqual(decoded?.modifiers, b.modifiers)
    }

    /// A binding with no modifiers still round-trips.
    func testHotkeyBindingNoModifiersRoundTrip() {
        let b = HotkeyBinding(keyCode: 0x24, modifiers: 0)
        XCTAssertNotNil(HotkeyBinding(encoded: b.encoded))
    }

    /// Malformed encodings return nil rather than crashing.
    func testHotkeyBindingMalformedReturnsNil() {
        XCTAssertNil(HotkeyBinding(encoded: "not-a-binding"))
        XCTAssertNil(HotkeyBinding(encoded: "12"))
        XCTAssertNil(HotkeyBinding(encoded: "a:b"))
    }

    /// Default bindings cover all registered action IDs and are distinct.
    func testDefaultBindingsExistAndAreDistinct() {
        let defaults = HotkeyBinding.defaults
        for id in HotkeyActionID.allCases {
            XCTAssertNotNil(defaults[id], "missing default for \(id)")
        }
        let combos = defaults.values.map { "\($0.keyCode)-\($0.modifiers)" }
        XCTAssertEqual(Set(combos).count, combos.count, "default hotkey combos must be distinct")
    }

    /// `HotkeyActionID` raw values use the `mv.hotkey.*` namespace.
    func testHotkeyActionIDNamespace() {
        for id in HotkeyActionID.allCases {
            XCTAssertTrue(id.prefKey.hasPrefix("mv.hotkey."), "pref key must be mv.hotkey.*: \(id.prefKey)")
        }
    }

    // MARK: - HotkeyActionID → ControlAction press/release mapping

    /// Momentary bypass press maps to .bypassMomentaryDown; release to .bypassMomentaryUp.
    func testBypassMomentaryPressReleaseMapping() {
        XCTAssertEqual(HotkeyActionID.bypassMomentary.action(pressed: true), .bypassMomentaryDown)
        XCTAssertEqual(HotkeyActionID.bypassMomentary.action(pressed: false), .bypassMomentaryUp)
    }

    /// Non-momentary actions fire only on press; release is ignored (nil).
    func testNonMomentaryFiresOnPressOnly() {
        XCTAssertEqual(HotkeyActionID.toggleAI.action(pressed: true), .toggleAI)
        XCTAssertNil(HotkeyActionID.toggleAI.action(pressed: false))
        XCTAssertEqual(HotkeyActionID.bypassToggle.action(pressed: true), .bypassToggle)
        XCTAssertNil(HotkeyActionID.bypassToggle.action(pressed: false))
    }

    // MARK: - ControlReducer: cycling

    func testPresetNextWraps() {
        var s = ControlState(preset: VoicePreset.allCases.last!)
        s = ControlReducer.reduce(s, .presetNext)
        XCTAssertEqual(s.preset, VoicePreset.allCases.first!, "cycling past last preset wraps to first")
    }

    func testPresetPrevWraps() {
        var s = ControlState(preset: VoicePreset.allCases.first!)
        s = ControlReducer.reduce(s, .presetPrev)
        XCTAssertEqual(s.preset, VoicePreset.allCases.last!, "cycling before first preset wraps to last")
    }

    func testClarityNextWraps() {
        var s = ControlState(clarity: ClarityLevel.allCases.last!)
        s = ControlReducer.reduce(s, .clarityNext)
        XCTAssertEqual(s.clarity, ClarityLevel.allCases.first!, "cycling past last clarity wraps to first")
    }

    // MARK: - ControlReducer: gain clamping (matches the 0.5...4.0 slider)

    func testGainUpClampsToMax() {
        var s = ControlState(gain: 3.95)
        s = ControlReducer.reduce(s, .gainUp)
        XCTAssertEqual(s.gain, 4.0, accuracy: 0.0001, "gain up clamps to slider max 4.0")
    }

    func testGainDownClampsToMin() {
        var s = ControlState(gain: 0.55)
        s = ControlReducer.reduce(s, .gainDown)
        XCTAssertEqual(s.gain, 0.5, accuracy: 0.0001, "gain down clamps to slider min 0.5")
    }

    // MARK: - ControlReducer: desired-vs-effective AI under bypass

    /// toggleAI flips both desired and effective AI when NOT bypassed.
    func testToggleAINotBypassed() {
        var s = ControlState(desiredAI: true)
        s = ControlReducer.reduce(s, .toggleAI)
        XCTAssertFalse(s.desiredAI)
        XCTAssertFalse(s.effectiveAI)
    }

    /// Sequence: bypass↓ → toggleAI → bypass↑. AI must come back OFF (the toggle won),
    /// NOT back ON from the pre-bypass value — this is the state hole the reducer fixes.
    func testBypassDownToggleAIBypassUpHonoursToggle() {
        var s = ControlState(desiredAI: true)
        s = ControlReducer.reduce(s, .bypassMomentaryDown)
        XCTAssertFalse(s.effectiveAI, "bypass forces effective AI off")
        XCTAssertTrue(s.desiredAI, "desired AI unchanged by bypass")
        s = ControlReducer.reduce(s, .toggleAI)
        XCTAssertFalse(s.desiredAI, "toggle while bypassed flips desired")
        XCTAssertFalse(s.effectiveAI, "still bypassed, effective stays off")
        s = ControlReducer.reduce(s, .bypassMomentaryUp)
        XCTAssertFalse(s.effectiveAI, "on bypass exit, effective follows the NEW desired (off)")
        XCTAssertFalse(s.desiredAI)
    }

    /// Sequence: bypass↑ from a clean ON state restores AI ON.
    func testBypassExitRestoresDesired() {
        var s = ControlState(desiredAI: true)
        s = ControlReducer.reduce(s, .bypassToggle)   // bypass on
        XCTAssertFalse(s.effectiveAI)
        s = ControlReducer.reduce(s, .bypassToggle)   // bypass off
        XCTAssertTrue(s.effectiveAI, "exiting bypass restores desired AI ON")
    }

    /// Momentary + toggle overlap: effective bypass is the OR; releasing momentary while
    /// toggle is still latched keeps bypass active.
    func testMomentaryAndToggleOverlap() {
        var s = ControlState(desiredAI: true)
        s = ControlReducer.reduce(s, .bypassToggle)        // toggle latched on
        s = ControlReducer.reduce(s, .bypassMomentaryDown) // momentary also on
        XCTAssertFalse(s.effectiveAI)
        s = ControlReducer.reduce(s, .bypassMomentaryUp)   // momentary released
        XCTAssertFalse(s.effectiveAI, "toggle still latched → still bypassed")
        s = ControlReducer.reduce(s, .bypassToggle)        // toggle off
        XCTAssertTrue(s.effectiveAI, "both released → AI restored")
    }

    /// Bypass toggle then a preset change: preset cycling works while bypassed and does
    /// not disturb bypass.
    func testBypassThenPresetCycle() {
        var s = ControlState(desiredAI: true, preset: VoicePreset.allCases.first!)
        s = ControlReducer.reduce(s, .bypassToggle)
        s = ControlReducer.reduce(s, .presetNext)
        XCTAssertEqual(s.preset, VoicePreset.allCases[1])
        XCTAssertFalse(s.effectiveAI, "preset change does not lift bypass")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ControlLayerTests
```

Expected: compile error — `cannot find type 'ControlAction' in scope`.

- [ ] **Step 3: Implement the pure control layer in `Core`**

Create `Sources/Core/ControlLayer.swift`:

```swift
import Foundation

// MARK: - ControlAction

/// Every user-facing action the control layer can fire. Pure value type — no AppKit,
/// no Carbon, no AudioModel. Safe to construct from hotkey callbacks, URL opens, or
/// CLI verbs. Lives in Core so the test target can exercise the parsers + reducer.
public enum ControlAction: Equatable, Sendable {
    case toggleAI
    case bypassMomentaryDown   // hotkey held — activate momentary bypass
    case bypassMomentaryUp     // hotkey released — deactivate momentary bypass
    case bypassToggle          // URL/CLI/latching hotkey — flip the latched bypass
    case presetNext
    case presetPrev
    case clarityNext
    case gainUp
    case gainDown

    // Gain nudge + clamp values. These MUST match the Settings → General "Output Gain"
    // slider range (0.5...4.0 in SettingsView.gainCard) so a nudge never lands outside
    // what the slider can show.
    public static let gainStep: Float = 0.1
    public static let gainMin: Float = 0.5
    public static let gainMax: Float = 4.0

    // MARK: URL parsing

    /// Parse a `nonoisemac://` URL into a `ControlAction`. Returns nil for unknown
    /// schemes or verbs so callers can silently ignore unrecognised links.
    public static func from(url: URL) -> ControlAction? {
        guard url.scheme?.lowercased() == "nonoisemac" else { return nil }
        // In custom-scheme URLs the verb is the host; sub-verb is the first path component.
        // e.g. nonoisemac://preset/next → host="preset", sub="next".
        let host = url.host?.lowercased() ?? ""
        let sub = url.pathComponents.dropFirst().first?.lowercased() ?? ""
        switch (host, sub) {
        case ("toggle", _):       return .toggleAI
        case ("bypass", _):       return .bypassToggle
        case ("preset", "next"):  return .presetNext
        case ("preset", "prev"):  return .presetPrev
        case ("clarity", "next"): return .clarityNext
        case ("gain", "up"):      return .gainUp
        case ("gain", "down"):    return .gainDown
        default:                  return nil
        }
    }

    // MARK: CLI verb parsing

    /// Parse a CLI verb string (e.g. "preset-next") into a `ControlAction`.
    public static func from(cliVerb verb: String) -> ControlAction? {
        switch verb.lowercased() {
        case "toggle":       return .toggleAI
        case "bypass":       return .bypassToggle
        case "preset-next":  return .presetNext
        case "preset-prev":  return .presetPrev
        case "clarity-next": return .clarityNext
        case "gain-up":      return .gainUp
        case "gain-down":    return .gainDown
        default:             return nil
        }
    }
}

// MARK: - HotkeyModifier

/// Modifier flags stored in a `HotkeyBinding`. Raw bit values are chosen to match the
/// AppKit `NSEvent.ModifierFlags` device-independent bits (command 1<<20, shift 1<<17,
/// option 1<<19, control 1<<18) so the App-boundary adapter is a no-op cast. Core itself
/// never imports AppKit — the mask is a plain `UInt32`.
public enum HotkeyModifier: UInt32, Sendable {
    case capsLock = 0x010000   // 1 << 16
    case shift    = 0x020000   // 1 << 17
    case control  = 0x040000   // 1 << 18
    case option   = 0x080000   // 1 << 19
    case command  = 0x100000   // 1 << 20
}

// MARK: - HotkeyActionID

/// The set of actions that can have a hotkey. Raw value is the UserDefaults key
/// (under the mv.* namespace to match existing persistence conventions).
public enum HotkeyActionID: String, CaseIterable, Sendable {
    case toggleAI        = "mv.hotkey.toggleAI"
    case bypassMomentary = "mv.hotkey.bypassMomentary"
    case bypassToggle    = "mv.hotkey.bypassToggle"
    case presetNext      = "mv.hotkey.presetNext"
    case presetPrev      = "mv.hotkey.presetPrev"
    case clarityNext     = "mv.hotkey.clarityNext"
    case gainUp          = "mv.hotkey.gainUp"
    case gainDown        = "mv.hotkey.gainDown"

    /// UserDefaults key for this binding.
    public var prefKey: String { rawValue }

    /// Map a Carbon press/release event for this action ID to a `ControlAction`.
    /// Only momentary bypass cares about release; all other actions fire on press only.
    public func action(pressed: Bool) -> ControlAction? {
        switch self {
        case .bypassMomentary:
            return pressed ? .bypassMomentaryDown : .bypassMomentaryUp
        case .toggleAI:     return pressed ? .toggleAI : nil
        case .bypassToggle: return pressed ? .bypassToggle : nil
        case .presetNext:   return pressed ? .presetNext : nil
        case .presetPrev:   return pressed ? .presetPrev : nil
        case .clarityNext:  return pressed ? .clarityNext : nil
        case .gainUp:       return pressed ? .gainUp : nil
        case .gainDown:     return pressed ? .gainDown : nil
        }
    }
}

// MARK: - HotkeyBinding

/// A key-code + modifier mask pair. The modifier mask is a plain `UInt32` (HotkeyModifier
/// bits) — Core does NOT import AppKit. Stored and restored as a compact string
/// "<keyCode>:<modifierMask>" in UserDefaults so there is no JSON/Codable overhead.
public struct HotkeyBinding: Equatable, Sendable {
    /// Virtual key code (Carbon kVK_* constants, e.g. kVK_ANSI_N = 0x2D).
    public let keyCode: UInt32
    /// Modifier mask built from `HotkeyModifier` raw bits (command|shift|option|control).
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: Persistence

    /// Compact string encoding: "<keyCode>:<modifierMask>".
    public var encoded: String { "\(keyCode):\(modifiers)" }

    /// Decode from the compact string. Returns nil if malformed.
    public init?(encoded: String) {
        let parts = encoded.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let kc = UInt32(parts[0]),
              let mod = UInt32(parts[1]) else { return nil }
        keyCode = kc
        modifiers = mod
    }

    // MARK: Defaults

    /// Default hotkey bindings. Sane starting combos that avoid common macOS system
    /// shortcuts. All use ⌃⌥ (Control+Option) as the base modifier. Key codes are the
    /// Carbon kVK_ANSI_* virtual key codes (named here as raw hex so Core needs no
    /// Carbon import; HotkeyManager validates them against kVK_* on registration).
    ///
    /// Written to UserDefaults on first launch; never overwritten by an update.
    public static let defaults: [HotkeyActionID: HotkeyBinding] = {
        let ctrlOpt = HotkeyModifier.control.rawValue | HotkeyModifier.option.rawValue
        let ctrlOptShift = ctrlOpt | HotkeyModifier.shift.rawValue
        return [
            // ⌃⌥N — toggle Noise Cancellation        (kVK_ANSI_N = 0x2D)
            .toggleAI:        HotkeyBinding(keyCode: 0x2D, modifiers: ctrlOpt),
            // ⌃⌥B — momentary bypass (hold for raw)   (kVK_ANSI_B = 0x0B)
            .bypassMomentary: HotkeyBinding(keyCode: 0x0B, modifiers: ctrlOpt),
            // ⌃⌥⇧B — bypass toggle (latching)         (kVK_ANSI_B = 0x0B)
            .bypassToggle:    HotkeyBinding(keyCode: 0x0B, modifiers: ctrlOptShift),
            // ⌃⌥] — next preset                       (kVK_ANSI_RightBracket = 0x1E)
            .presetNext:      HotkeyBinding(keyCode: 0x1E, modifiers: ctrlOpt),
            // ⌃⌥[ — previous preset                   (kVK_ANSI_LeftBracket = 0x21)
            .presetPrev:      HotkeyBinding(keyCode: 0x21, modifiers: ctrlOpt),
            // ⌃⌥C — cycle Broadcast Voice clarity     (kVK_ANSI_C = 0x08)
            .clarityNext:     HotkeyBinding(keyCode: 0x08, modifiers: ctrlOpt),
            // ⌃⌥= — gain up                           (kVK_ANSI_Equal = 0x18)
            .gainUp:          HotkeyBinding(keyCode: 0x18, modifiers: ctrlOpt),
            // ⌃⌥- — gain down                         (kVK_ANSI_Minus = 0x1B)
            .gainDown:        HotkeyBinding(keyCode: 0x1B, modifiers: ctrlOpt),
        ]
    }()
}

// MARK: - ControlState

/// A pure snapshot of the control-layer-relevant state. The App-side adapter reads this
/// from `AudioModel`, runs the reducer, and writes the result back. Bypass fields are
/// session-only (never persisted). `desiredAI` is the user's intended AI on/off ignoring
/// bypass; `effectiveAI` (computed) is what AudioModel.isAIEnabled is set to.
public struct ControlState: Equatable, Sendable {
    public var desiredAI: Bool
    public var isBypassedMomentary: Bool
    public var isBypassedToggle: Bool
    public var preset: VoicePreset
    public var clarity: ClarityLevel
    public var gain: Float

    public init(desiredAI: Bool = true,
                isBypassedMomentary: Bool = false,
                isBypassedToggle: Bool = false,
                preset: VoicePreset = .meeting,
                clarity: ClarityLevel = .off,
                gain: Float = 1.0) {
        self.desiredAI = desiredAI
        self.isBypassedMomentary = isBypassedMomentary
        self.isBypassedToggle = isBypassedToggle
        self.preset = preset
        self.clarity = clarity
        self.gain = gain
    }

    /// Effective bypass = momentary OR latched toggle.
    public var isBypassed: Bool { isBypassedMomentary || isBypassedToggle }

    /// What AudioModel.isAIEnabled should be: desired AI, suppressed while bypassed.
    public var effectiveAI: Bool { desiredAI && !isBypassed }
}

// MARK: - ControlReducer

/// Pure state transitions for the control layer. The ONLY place the bypass + AI logic
/// lives — `ActionDispatcher` (App) is a thin adapter that reads `ControlState` from
/// `AudioModel`, calls `reduce`, and writes the result back. No AudioModel, no AppKit.
public enum ControlReducer {

    public static func reduce(_ state: ControlState, _ action: ControlAction) -> ControlState {
        var s = state
        switch action {
        case .toggleAI:
            // Flip the DESIRED state regardless of bypass. effectiveAI recomputes from it.
            s.desiredAI.toggle()

        case .bypassMomentaryDown:
            s.isBypassedMomentary = true

        case .bypassMomentaryUp:
            s.isBypassedMomentary = false

        case .bypassToggle:
            s.isBypassedToggle.toggle()

        case .presetNext:
            let cases = VoicePreset.allCases
            if let idx = cases.firstIndex(of: s.preset) {
                s.preset = cases[(idx + 1) % cases.count]
            }

        case .presetPrev:
            let cases = VoicePreset.allCases
            if let idx = cases.firstIndex(of: s.preset) {
                s.preset = cases[(idx - 1 + cases.count) % cases.count]
            }

        case .clarityNext:
            let cases = ClarityLevel.allCases
            if let idx = cases.firstIndex(of: s.clarity) {
                s.clarity = cases[(idx + 1) % cases.count]
            }

        case .gainUp:
            s.gain = min(s.gain + ControlAction.gainStep, ControlAction.gainMax)

        case .gainDown:
            s.gain = max(s.gain - ControlAction.gainStep, ControlAction.gainMin)
        }
        return s
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter ControlLayerTests
```

Expected: all tests PASS. These models + the reducer are the REAL dispatch logic — the App-side
`ActionDispatcher` (Task 3) re-uses `ControlReducer.reduce` verbatim, so this is not a test-only
shadow implementation.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ControlLayer.swift Tests/NoNoiseMacTests/ControlLayerTests.swift
git commit -m "feat(control): add pure ControlAction/HotkeyBinding/ControlReducer to Core (testable)"
```

---

## Task 2: `ActionDispatcher` adapter + Carbon `HotkeyManager` — App layer

Build the App-side layer on top of the pure Core models from Task 1: the `ActionDispatcher`
(adapts `ControlReducer` onto a live `AudioModel`) and the Carbon `HotkeyManager` (registers
system-wide hotkeys and routes them through the dispatcher). Both are `@MainActor` and conform to
`ObservableObject` because the UI observes them (`@ObservedObject` / `@StateObject`).

No new XCTest here — the real dispatch logic is already tested via `ControlReducer` in Task 1
(`ActionDispatcher` is a thin adapter that cannot be constructed headlessly because it depends on
`AudioModel`, which starts CoreAudio). Verified by build.

**Files:**
- Create: `Sources/App/ActionDispatcher.swift`
- Create: `Sources/App/HotkeyManager.swift`

### Step 1: Implement the `ActionDispatcher` adapter

Create `Sources/App/ActionDispatcher.swift`:

```swift
import Foundation
import Combine   // ObservableObject / @Published
import Core

/// Adapts the pure `ControlReducer` onto a live `AudioModel`. Owns the session-only A/B
/// bypass state and the canonical `desiredAI` flag. Must be held for the app's lifetime.
///
/// All mutations run on the main thread (`@MainActor`); callers from other threads MUST hop
/// to the main actor first. AudioModel's `@Published` knobs are written from main exactly
/// like the existing UI bindings (the render thread reads lock-free arm64 scalars — see
/// AGENTS.md "Real-time audio rules").
@MainActor
public final class ActionDispatcher: ObservableObject {

    private weak var model: AudioModel?

    /// Pure state snapshot. Seeded from AudioModel on init; the reducer is the single source
    /// of bypass + desired-AI truth. `gain`/`preset`/`clarity` are re-synced from the model on
    /// every dispatch so external changes (UI sliders, presets) are not clobbered.
    private var state: ControlState

    /// Mirrors `state.isBypassed` for the SwiftUI bypass banner (Task 6).
    @Published public private(set) var isBypassed: Bool = false

    public init(model: AudioModel) {
        self.model = model
        // Seed desired-AI from the model's current (persisted) value.
        self.state = ControlState(desiredAI: model.isAIEnabled,
                                  preset: model.selectedPreset,
                                  clarity: model.clarityLevel,
                                  gain: model.outputGainValue)
    }

    // MARK: - Dispatch

    /// Run one action through the pure reducer and push the resulting state to AudioModel.
    public func dispatch(_ action: ControlAction) {
        guard let model = model else { return }

        // Re-sync the value-knob fields from the model so concurrent UI edits aren't lost.
        // `desiredAI` and the bypass flags are owned by the reducer and intentionally NOT
        // re-read here — while bypassed, model.isAIEnabled is forced false and would corrupt
        // `desiredAI` if read back.
        state.preset = model.selectedPreset
        state.clarity = model.clarityLevel
        state.gain = model.outputGainValue
        if !state.isBypassed {
            // When not bypassed, model.isAIEnabled IS the desired value — keep them in sync
            // so a UI toggle is reflected before a hotkey toggle.
            state.desiredAI = model.isAIEnabled
        }

        state = ControlReducer.reduce(state, action)

        // Push the reduced state back onto the model.
        model.selectedPreset = state.preset
        model.clarityLevel = state.clarity
        model.outputGainValue = state.gain
        model.isAIEnabled = state.effectiveAI   // desiredAI suppressed while bypassed

        isBypassed = state.isBypassed
    }
}
```

### Step 2: Implement the Carbon `HotkeyManager`

Create `Sources/App/HotkeyManager.swift`:

```swift
import Foundation
import AppKit            // NSEvent.ModifierFlags (modifier-mask adapter)
import Combine           // ObservableObject / @Published (UI observes conflictedActions)
import Carbon.HIToolbox  // RegisterEventHotKey, kVK_*, EventHotKeyID
import Core              // HotkeyActionID, HotkeyBinding, HotkeyModifier, ControlAction

/// Registers and manages system-wide Carbon hotkeys. Must be created and retained for the
/// lifetime of the app. All methods run on the main thread (`@MainActor`).
///
/// **Why Carbon `RegisterEventHotKey` and not `NSEvent.addGlobalMonitorForEvents`:**
/// Carbon hotkeys work under the hardened runtime with the existing two entitlements
/// (audio-input + allow-jit) and require NO additional permissions. NSEvent global monitors
/// require Accessibility permission (a user-visible prompt) — deliberately avoided to keep the
/// entitlement surface minimal (see AGENTS.md "Entitlements & signing").
@MainActor
public final class HotkeyManager: ObservableObject {

    private let dispatcher: ActionDispatcher
    private var registrations: [HotkeyActionID: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    /// Deterministic EventHotKeyID.id per action — its position in `HotkeyActionID.allCases`
    /// plus 1 (never 0). NOT a hash: hashValue is randomized per process and would make the
    /// fired ID un-matchable back to its action.
    private static let actionOrder: [HotkeyActionID] = HotkeyActionID.allCases
    private func hotKeyNumericID(for action: HotkeyActionID) -> UInt32 {
        UInt32((Self.actionOrder.firstIndex(of: action) ?? 0) + 1)
    }
    private func action(forNumericID id: UInt32) -> HotkeyActionID? {
        let idx = Int(id) - 1
        guard idx >= 0, idx < Self.actionOrder.count else { return nil }
        return Self.actionOrder[idx]
    }

    /// Current active bindings (loaded from UserDefaults or defaults).
    @Published public private(set) var bindings: [HotkeyActionID: HotkeyBinding] = [:]
    /// Action IDs whose preferred binding collided with another app (eventHotKeyExistsErr).
    @Published public private(set) var conflictedActions: Set<HotkeyActionID> = []

    public init(dispatcher: ActionDispatcher) {
        self.dispatcher = dispatcher
        loadBindings()
        installEventHandler()
        registerAll()
    }

    deinit {
        // deinit is nonisolated; tear down Carbon registrations directly (no actor hop needed —
        // UnregisterEventHotKey/RemoveEventHandler are thread-safe C calls).
        for (_, ref) in registrations { UnregisterEventHotKey(ref) }
        if let h = eventHandler { RemoveEventHandler(h) }
    }

    // MARK: - Public API

    /// Update the binding for a single action: unregisters the old combo, persists the new
    /// one, and re-registers. Returns true if registration succeeded.
    @discardableResult
    public func rebind(action: HotkeyActionID, to binding: HotkeyBinding) -> Bool {
        unregister(action)
        bindings[action] = binding
        UserDefaults.standard.set(binding.encoded, forKey: action.prefKey)
        return register(action: action, binding: binding)
    }

    // MARK: - Persistence

    private func loadBindings() {
        let d = UserDefaults.standard
        for id in HotkeyActionID.allCases {
            if let raw = d.string(forKey: id.prefKey), let b = HotkeyBinding(encoded: raw) {
                bindings[id] = b
            } else if let def = HotkeyBinding.defaults[id] {
                // First launch: write and use the default.
                bindings[id] = def
                d.set(def.encoded, forKey: id.prefKey)
            }
        }
    }

    // MARK: - Carbon registration

    private func installEventHandler() {
        var spec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // Pass `self` as userData (unretained — HotkeyManager is owned by the app and lives forever).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 2, &spec, selfPtr, &eventHandler)
    }

    private func registerAll() {
        for (id, binding) in bindings { register(action: id, binding: binding) }
    }

    @discardableResult
    private func register(action: HotkeyActionID, binding: HotkeyBinding) -> Bool {
        let carbonMods = Self.carbonModifiers(from: binding.modifiers)
        let hotKeyID = EventHotKeyID(signature: Self.fourCC("NoNM"), id: hotKeyNumericID(for: action))
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(binding.keyCode, carbonMods, hotKeyID,
                                      GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let ref = ref {
            registrations[action] = ref
            conflictedActions.remove(action)
            return true
        } else {
            // eventHotKeyExistsErr (-9878): another app owns this combo. Surface it in UI.
            conflictedActions.insert(action)
            return false
        }
    }

    private func unregister(_ action: HotkeyActionID) {
        if let ref = registrations.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }

    // MARK: - Event dispatch

    /// Called (on the main thread) by the Carbon C shim. Matches the fired EventHotKeyID back
    /// to its action via the deterministic numeric ID, then dispatches the mapped ControlAction.
    fileprivate func handleHotKeyEvent(numericID: UInt32, pressed: Bool) {
        guard let actionID = action(forNumericID: numericID) else { return }
        if let controlAction = actionID.action(pressed: pressed) {
            dispatcher.dispatch(controlAction)
        }
    }

    // MARK: - Helpers (modifier-mask adapter: Core UInt32 → Carbon mask)

    /// Adapt the Core `HotkeyModifier` mask (NSEvent device-independent bits) to a Carbon
    /// modifier mask. This is the ONLY place the two representations meet.
    private static func carbonModifiers(from mask: UInt32) -> UInt32 {
        var out: UInt32 = 0
        if mask & HotkeyModifier.command.rawValue != 0 { out |= UInt32(cmdKey) }
        if mask & HotkeyModifier.shift.rawValue   != 0 { out |= UInt32(shiftKey) }
        if mask & HotkeyModifier.option.rawValue  != 0 { out |= UInt32(optionKey) }
        if mask & HotkeyModifier.control.rawValue != 0 { out |= UInt32(controlKey) }
        return out
    }

    private static func fourCC(_ s: String) -> OSType {
        let bytes = Array(s.utf8)
        guard bytes.count >= 4 else { return 0 }
        return OSType(bytes[0]) << 24 | OSType(bytes[1]) << 16 | OSType(bytes[2]) << 8 | OSType(bytes[3])
    }
}

// MARK: - Carbon event handler (C-compatible function)

/// Top-level C callback required by `InstallEventHandler`. Reads the fired EventHotKeyID off
/// the Carbon event, then hops to the main actor before touching `HotkeyManager` (which is
/// `@MainActor`). Carbon delivers this on the main run loop in a menu-bar app, but the explicit
/// `Task { @MainActor }` hop satisfies Swift concurrency isolation and is correct even if the
/// thread assumption ever changes.
private func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)

    // Extract the EventHotKeyID synchronously (the EventRef is only valid for this call).
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let numericID = hotkeyID.id

    // Hop to the main actor; HotkeyManager + ActionDispatcher are @MainActor.
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        manager.handleHotKeyEvent(numericID: numericID, pressed: pressed)
    }
    return noErr
}
```

> **Why these fixes vs. the reviewer's findings:**
> - `ObservableObject` conformance is now explicit on BOTH `ActionDispatcher` and
>   `HotkeyManager`, so `@ObservedObject` / `@StateObject` and `@Published` compile.
> - `import AppKit` + `import Combine` + `import Carbon.HIToolbox` are all present; the Core
>   models supply `HotkeyActionID` / `HotkeyBinding` / `HotkeyModifier` / `ControlAction`.
> - The C Carbon callback no longer calls a `@MainActor` method synchronously — it extracts the
>   `EventHotKeyID` (valid only during the callback) and then hops via `Task { @MainActor in … }`.
> - `EventHotKeyID.id` is DETERMINISTIC (`allCases` index + 1), not `rawValue.hashValue` — so the
>   fired ID reliably matches back to its action across process launches.

- [ ] **Step 3: Build**

```bash
swift build
```

Expected: build succeeds. The full test suite is unchanged from Task 1 (no new headless-testable
surface here):

```bash
swift test
```

Expected: all tests PASS (existing suite + Task 1 `ControlLayerTests`).

- [ ] **Step 4: Commit**

```bash
git add Sources/App/ActionDispatcher.swift Sources/App/HotkeyManager.swift
git commit -m "feat(hotkeys): add ActionDispatcher adapter + Carbon HotkeyManager (ObservableObject, main-actor bridge)"
```

---

## Task 3: Wire `ActionDispatcher` + `HotkeyManager` into the app lifecycle

`NoNoiseMacApp` creates the dispatcher AND the `HotkeyManager` at **app startup** (in `init()`),
holds both on `@StateObject`, passes references down to `ContentView`, and registers the
URL-scheme handler. `AppDelegate` gets a `application(_:open:)` fallback. No new entitlements.

> **Critical: hotkeys must register at launch, not on first popover open.** A `MenuBarExtra`'s
> content view is only instantiated when the popover is first shown, so `ContentView.onAppear`
> does NOT run at launch. Creating `HotkeyManager` in `onAppear` would leave every system-wide
> hotkey DEAD until the user clicks the menu-bar icon — defeating the entire feature (a streamer
> must be able to hit ⌃⌥B while focused in OBS, having never opened the popover). Both the
> dispatcher and the `HotkeyManager` are therefore created in `NoNoiseMacApp.init()` and retained
> on `@StateObject`, so Carbon registration happens during app launch.

**Files:**
- Modify: `Sources/App/NoNoiseMacApp.swift`
- Modify: `Sources/App/ContentView.swift` (add the `dispatcher` + `hotkeyManager` stored
  properties so the new `ContentView(...)` call site compiles; they are USED in Tasks 5–6).

- [ ] **Step 1: Add the new stored properties to `ContentView`**

In `Sources/App/ContentView.swift`, extend `ContentView`'s property block so the call site
below compiles (the properties are exercised by the bypass banner in Task 6 and the Settings
threading in Task 5):

```swift
struct ContentView: View {
    @ObservedObject var audioModel: AudioModel
    @ObservedObject var dispatcher: ActionDispatcher
    @ObservedObject var hotkeyManager: HotkeyManager
    // body unchanged in this task
```

- [ ] **Step 2: Update `NoNoiseMacApp.swift`**

Replace the entire file content with:

```swift
import SwiftUI
import Core

@main
struct NoNoiseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // The Core state machine, the action coordinator, and the Carbon hotkey layer are all
    // created ONCE in init() and retained on @StateObject for the app's lifetime. Creating
    // HotkeyManager here (NOT in ContentView.onAppear) guarantees global hotkeys are live
    // from launch — the MenuBarExtra content view doesn't instantiate until the popover opens.
    @StateObject var audioModel: AudioModel
    @StateObject private var dispatcher: ActionDispatcher
    @StateObject private var hotkeyManager: HotkeyManager

    init() {
        // Init order matters: AudioModel → ActionDispatcher(model:) → HotkeyManager(dispatcher:).
        let model = AudioModel()
        let dispatcher = ActionDispatcher(model: model)
        let hotkeys = HotkeyManager(dispatcher: dispatcher)   // registers Carbon hotkeys NOW
        _audioModel = StateObject(wrappedValue: model)
        _dispatcher = StateObject(wrappedValue: dispatcher)
        _hotkeyManager = StateObject(wrappedValue: hotkeys)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(audioModel: audioModel, dispatcher: dispatcher, hotkeyManager: hotkeyManager)
                .onAppear {
                    // Wire the URL fallback once the scene graph exists. Hotkeys are ALREADY
                    // registered (from init) — this only hands the dispatcher to AppDelegate.
                    appDelegate.dispatcher = dispatcher
                }
        } label: {
            Image(nsImage: NoNoiseLogoImage.menuBar(isActive: audioModel.isAIEnabled))
        }
        .menuBarExtraStyle(.window)
        // SwiftUI delivers URL opens to the scene via onOpenURL on macOS 13+.
        .onOpenURL { url in
            guard let action = ControlAction.from(url: url) else { return }
            dispatcher.dispatch(action)
        }
    }
}

// @MainActor on the whole delegate: AppKit delivers these callbacks on the main thread, and it
// lets us touch the @MainActor `dispatcher` and call `dispatch(_:)` without a concurrency error.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by NoNoiseMacApp once the scene appears (the dispatcher itself is created at launch).
    var dispatcher: ActionDispatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Fallback URL handler for cases where the SwiftUI onOpenURL doesn't fire
    /// (e.g. app already backgrounded and not in the active scene graph).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = ControlAction.from(url: url) else { continue }
            dispatcher?.dispatch(action)
        }
    }
}
```

> **Note (`@StateObject` cross-reference):** `HotkeyManager` holds a plain stored reference to
> `dispatcher`, which is itself an independent object created first in `init()`. There is no
> init-order cycle — both are fully constructed as local lets before being wrapped in
> `StateObject`. The earlier `@State var hotkeyManager: HotkeyManager?` + `onAppear` lazy-init
> approach is REJECTED precisely because it delays Carbon registration to first popover open.
>
> **Note (`@MainActor` construction in `App.init()`):** `ActionDispatcher` and `HotkeyManager`
> are `@MainActor`. SwiftUI calls `@main App.init()` on the main thread, and under this package's
> Swift 5.9 default concurrency checking this compiles cleanly (no `-strict-concurrency=complete`).
> If a future Swift-6 mode flags it, annotate the `init()` (or the App type) `@MainActor` — do NOT
> move construction back into `onAppear`, which would reintroduce the launch-timing bug.

- [ ] **Step 3: Build**

```bash
swift build
```

Expected: build succeeds. (At this point `ContentView` has the new stored properties but the body
does not yet read `dispatcher`/`hotkeyManager` — that lands in Tasks 5–6. SwiftUI tolerates unused
stored `@ObservedObject` properties, so the build is green.)

- [ ] **Step 4: Commit**

```bash
git add Sources/App/NoNoiseMacApp.swift Sources/App/ContentView.swift
git commit -m "feat(app): create dispatcher + HotkeyManager at launch (hotkeys live before popover opens)"
```

---

## Task 4: Register `nonoisemac://` URL scheme in `Info.plist`

Add the `CFBundleURLTypes` array so macOS routes `nonoisemac://` opens to our app. No new
entitlement is required — custom URL-scheme registration is a pure `Info.plist` declaration.

**Files:**
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Add `CFBundleURLTypes`**

In `Resources/Info.plist`, add the following block immediately before the closing `</dict>`:

```xml
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.ivalsaraj.NoNoiseMac</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>nonoisemac</string>
			</array>
		</dict>
	</array>
```

- [ ] **Step 2: Build**

```bash
swift build
```

Expected: build succeeds (SwiftPM copies `Info.plist` into the product bundle).

- [ ] **Step 3: Commit**

```bash
git add Resources/Info.plist
git commit -m "feat(url-scheme): register nonoisemac:// URL scheme in Info.plist"
```

> **Note on testing URL-scheme registration:** `swift build` / `swift run` do NOT register
> URL schemes — the Swift package runner doesn't install a proper `.app` bundle. URL-scheme
> handling must be verified via `./bundle.sh` + opening the resulting `NoNoiseMac.app` (Task 8
> smoke test step 5).

---

## Task 5: Hotkey Settings UI — view + rebind sheet

Add a **Hotkeys** tab to `SettingsView` so users can see current bindings and rebind any action.
A conflict warning is shown for collided slots. Threading the `hotkeyManager` reference into the
Settings window touches THREE files — all signatures and call sites are updated in this ONE task /
commit so the build never lands in a half-threaded state.

**Files:**
- Modify: `Sources/App/SettingsView.swift` — `HotkeySettingsView` + `RebindSheet` + `KeyCaptureView`;
  `SettingsView(audioModel:)` → `SettingsView(audioModel:hotkeyManager:)`.
- Modify: `Sources/App/ContentView.swift` — `ContentView` gains a `hotkeyManager` property;
  `WindowManager.openSettings(model:)` → `WindowManager.openSettings(model:hotkeyManager:)`; both
  `openSettings` call sites (header gear button + footer Settings button) pass `hotkeyManager`.
- (`Sources/App/NoNoiseMacApp.swift` already passes `hotkeyManager:` to `ContentView(...)` from
  Task 3 — no further change here.)

No XCTest (SwiftUI view) — verified by build + manual smoke test.

### Step 1: Add `HotkeySettingsView`

In `Sources/App/SettingsView.swift`, add the following after the existing `GeneralSettingsView`:

```swift
// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    @ObservedObject var manager: HotkeyManager
    @State private var rebindingAction: HotkeyActionID?
    @State private var isListeningForKey: Bool = false

    private let actionLabels: [(HotkeyActionID, String)] = [
        (.toggleAI,        "Toggle Noise Cancellation"),
        (.bypassMomentary, "A/B Bypass (hold for raw)"),
        (.bypassToggle,    "A/B Bypass (toggle)"),
        (.presetNext,      "Preset → Next"),
        (.presetPrev,      "Preset → Previous"),
        (.clarityNext,     "Broadcast Voice → Next Level"),
        (.gainUp,          "Output Gain +"),
        (.gainDown,        "Output Gain −"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Global Hotkeys")
                .font(.title3).fontWeight(.semibold)
                .padding(.bottom, 12)

            ForEach(actionLabels, id: \.0) { (id, label) in
                hotkeyRow(id: id, label: label)
                Divider()
            }

            if !manager.conflictedActions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Some hotkeys conflict with another app. Rebind them or change the conflicting app's shortcuts.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 10)
            }
        }
        .padding()
        .sheet(item: $rebindingAction) { id in
            RebindSheet(actionID: id, manager: manager)
        }
    }

    private func hotkeyRow(id: HotkeyActionID, label: String) -> some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if manager.conflictedActions.contains(id) {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                    .help("This combo is in use by another app")
            }
            if let b = manager.bindings[id] {
                Text(hotkeyDisplayString(b))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("—").foregroundColor(.secondary)
            }
            Button("Edit") { rebindingAction = id }
                .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private func hotkeyDisplayString(_ b: HotkeyBinding) -> String {
        var s = ""
        // b.modifiers is a plain UInt32 (Core HotkeyModifier bits) — test bits directly.
        let m = b.modifiers
        if m & HotkeyModifier.control.rawValue != 0 { s += "⌃" }
        if m & HotkeyModifier.option.rawValue  != 0 { s += "⌥" }
        if m & HotkeyModifier.shift.rawValue   != 0 { s += "⇧" }
        if m & HotkeyModifier.command.rawValue != 0 { s += "⌘" }
        // Map common kVK codes to printable glyphs (non-exhaustive — covers the default set).
        let keyGlyphs: [UInt32: String] = [
            0x2D: "N", 0x0B: "B", 0x1E: "]", 0x21: "[", 0x08: "C",
            0x18: "=", 0x1B: "-",
        ]
        s += keyGlyphs[b.keyCode] ?? "?\(b.keyCode)"
        return s
    }
}

// HotkeyActionID is declared in Core; add Identifiable conformance here (App-only, for SwiftUI).
extension HotkeyActionID: Identifiable {
    public var id: String { rawValue }
}

// MARK: - Rebind sheet

/// Key-capture sheet: wait for the user to press a key combo, then commit it.
/// Uses an invisible NSView subclass that overrides keyDown to capture the event.
struct RebindSheet: View {
    let actionID: HotkeyActionID
    @ObservedObject var manager: HotkeyManager
    @Environment(\.dismiss) var dismiss
    @State private var capturedBinding: HotkeyBinding?
    @State private var conflict: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Press a new key combo for:")
            Text(actionID.id.replacingOccurrences(of: "mv.hotkey.", with: ""))
                .font(.headline)
            KeyCaptureView { binding in
                capturedBinding = binding
                conflict = false
            }
            .frame(width: 200, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5))
            if let b = capturedBinding {
                Text("New: \(b.encoded)").font(.caption).foregroundColor(.secondary)
            }
            if conflict {
                Text("That combo is in use by another app.").foregroundColor(.orange).font(.caption)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    if let b = capturedBinding {
                        let ok = manager.rebind(action: actionID, to: b)
                        if ok { dismiss() } else { conflict = true }
                    }
                }
                .disabled(capturedBinding == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// NSViewRepresentable that captures the next key-down event and reports it
/// as a `HotkeyBinding` via the callback. The view becomes first responder
/// on appear to receive key events without Accessibility permission.
struct KeyCaptureView: NSViewRepresentable {
    var onCapture: (HotkeyBinding) -> Void

    func makeNSView(context: Context) -> _KeyCaptureNSView {
        let v = _KeyCaptureNSView()
        v.onCapture = onCapture
        return v
    }

    func updateNSView(_ nsView: _KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
    }
}

final class _KeyCaptureNSView: NSView {
    var onCapture: ((HotkeyBinding) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Ignore bare modifiers; wait for a real key code.
        guard event.keyCode != 0xFF else { return }
        // Adapt NSEvent.ModifierFlags → plain UInt32 mask at the App boundary. The relevant bits
        // (command/option/shift/control) share the same raw values as Core's HotkeyModifier, so
        // the masked rawValue maps 1:1.
        let masked = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode),
                                    modifiers: UInt32(masked.rawValue))
        onCapture?(binding)
    }
}
```

- [ ] **Step 2: Add the Hotkeys tab to `SettingsView` and accept `hotkeyManager`**

In `Sources/App/SettingsView.swift`, change `SettingsView` to take the manager and add the tab.
Replace the existing `SettingsView` struct with:

```swift
struct SettingsView: View {
    @ObservedObject var audioModel: AudioModel
    @ObservedObject var hotkeyManager: HotkeyManager

    var body: some View {
        TabView {
            GeneralSettingsView(audioModel: audioModel)
                .tabItem {
                    Label("General", systemImage: "slider.horizontal.3")
                }

            HotkeySettingsView(manager: hotkeyManager)
                .tabItem {
                    Label("Hotkeys", systemImage: "keyboard")
                }

            GuideView()
                .tabItem {
                    Label("Setup Guide", systemImage: "book.pages")
                }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 440)
    }
}
```

- [ ] **Step 3: Thread `hotkeyManager` through `ContentView` and `WindowManager`**

In `Sources/App/ContentView.swift` (`ContentView` already has the `hotkeyManager` stored
property from Task 3 — here we start USING it):

1. Update BOTH `openSettings` call sites — the header gear button and the footer Settings
   button — to pass `hotkeyManager`:

```swift
// header gear button
Button {
    WindowManager.openSettings(model: audioModel, hotkeyManager: hotkeyManager)
} label: {
    Image(systemName: "gearshape.fill")
        .font(.system(size: 14))
        .foregroundColor(.secondary)
}
.buttonStyle(.plain)
.help("Settings")
```

```swift
// footer Settings button
Button {
    WindowManager.openSettings(model: audioModel, hotkeyManager: hotkeyManager)
} label: {
    Label("Settings", systemImage: "slider.horizontal.3")
}
.controlSize(.small)
```

2. Update `WindowManager.openSettings` to take and forward `hotkeyManager`:

```swift
static func openSettings(model: AudioModel, hotkeyManager: HotkeyManager) {
    if settingsWindow == nil {
        let view = SettingsView(audioModel: model, hotkeyManager: hotkeyManager)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.center()
        panel.title = "NoNoise Mac Settings"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: view)
        panel.isFloatingPanel = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 420)

        settingsWindow = panel

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: nil) { _ in
            settingsWindow = nil
        }
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
```

> All four touch points — `SettingsView` init, `WindowManager.openSettings`, and the two
> `ContentView` call sites — change together. `NoNoiseMacApp` already passes
> `hotkeyManager: hotkeyManager` into `ContentView(...)` from Task 3.

- [ ] **Step 4: Build**

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/SettingsView.swift Sources/App/ContentView.swift
git commit -m "feat(ui): add Hotkeys settings tab + thread hotkeyManager through ContentView/WindowManager"
```

---

## Task 6: A/B Bypass UI indicator in the menu-bar popover

Show a transient "A/B Bypass — hearing raw mic" banner in `ContentView` when bypass is
active, so the user knows they are in passthrough mode.

**Files:**
- Modify: `Sources/App/ContentView.swift`

No XCTest — build + manual.

- [ ] **Step 1: Confirm the `dispatcher` property**

`ContentView` already declares `@ObservedObject var dispatcher: ActionDispatcher` (added in
Task 3) and `NoNoiseMacApp` already passes `dispatcher: dispatcher`. This task adds the first
use of `dispatcher.isBypassed` in the body.

- [ ] **Step 2: Add the bypass indicator**

Add a `bypassBanner` computed view:

```swift
    @ViewBuilder
    private var bypassBanner: some View {
        if dispatcher.isBypassed {
            HStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("A/B Bypass Active").font(.caption).fontWeight(.medium).foregroundColor(.orange)
                    Text("Hearing raw mic — AI off while bypass is on.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
            }
            .nnCard()
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
```

Add `bypassBanner` to `body`'s `VStack`, immediately after `statusCard`:

```swift
        VStack(spacing: 14) {
            header
            statusCard
            bypassBanner
            modeCard
            // ... rest unchanged
        }
        .animation(.easeInOut(duration: 0.18), value: dispatcher.isBypassed)
```

- [ ] **Step 3: Build**

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/ContentView.swift
git commit -m "feat(ui): show A/B bypass active banner in menu-bar popover"
```

---

## Task 7: `NoNoiseMacCLI` action verbs

Extend `Sources/CLI/main.swift` with `--action <verb>` to support one-shot control from
shell scripts, Alfred, Automator, or Stream Deck's "Shell" action.

**Files:**
- Modify: `Sources/CLI/main.swift`

No XCTest (CLI bootstrap depends on CoreAudio).

- [ ] **Step 1: Add `--action` flag parsing**

In `Sources/CLI/main.swift`, extend the argument parser and add action handling:

```swift
import Foundation
import Core

print("NoNoise Mac CLI 🎙️")

var inputName: String?
var outputName: String?
var gain: Float = 1.0
var actionVerb: String?

var args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "--in":
        if i + 1 < args.count { inputName = args[i + 1]; i += 1 }
    case "--out":
        if i + 1 < args.count { outputName = args[i + 1]; i += 1 }
    case "--gain":
        if i + 1 < args.count, let g = Float(args[i + 1]) { gain = g; i += 1 }
    case "--action":
        if i + 1 < args.count { actionVerb = args[i + 1]; i += 1 }
    case "--help":
        print("""
        Usage:
          NoNoiseMacCLI --in <device> --out <device> [--gain <float>]
          NoNoiseMacCLI --action <verb>

        Action verbs (send a one-shot control to the running app via URL scheme):
          toggle         Toggle Noise Cancellation
          bypass         Toggle A/B bypass (passthrough)
          preset-next    Cycle preset forward
          preset-prev    Cycle preset backward
          clarity-next   Cycle Broadcast Voice clarity forward
          gain-up        Nudge output gain up
          gain-down      Nudge output gain down

        URL scheme (Stream Deck / scripting):
          open nonoisemac://toggle
          open nonoisemac://bypass
          open nonoisemac://preset/next
          open nonoisemac://preset/prev
          open nonoisemac://clarity/next
          open nonoisemac://gain/up
          open nonoisemac://gain/down
        """)
        exit(0)
    default:
        break
    }
    i += 1
}

// One-shot action mode: send the verb as a URL open and exit.
// The running .app handles it via the nonoisemac:// URL scheme handler.
if let verb = actionVerb {
    let urlStrings: [String: String] = [
        "toggle":       "nonoisemac://toggle",
        "bypass":       "nonoisemac://bypass",
        "preset-next":  "nonoisemac://preset/next",
        "preset-prev":  "nonoisemac://preset/prev",
        "clarity-next": "nonoisemac://clarity/next",
        "gain-up":      "nonoisemac://gain/up",
        "gain-down":    "nonoisemac://gain/down",
    ]
    guard let urlStr = urlStrings[verb], let url = URL(string: urlStr) else {
        print("Error: Unknown action verb '\(verb)'. Run --help for the list.")
        exit(1)
    }
    // NSWorkspace.open delivers the URL to the registered app (NoNoiseMac.app).
    // This requires the .app to be running; the CLI exits immediately after.
    NSWorkspace.shared.open(url)
    print("Sent action '\(verb)' to NoNoise Mac.")
    exit(0)
}

// Pipeline mode (unchanged)
guard let input = inputName, let output = outputName else {
    print("Error: Missing --in or --out.")
    print("Run --help for usage.")
    exit(1)
}

let model = AudioModel()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))

if let inDev = model.inputDevices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(input) }) {
    print("Selecting Input: \(inDev.localizedName)")
    model.selectedInputDeviceID = inDev.uniqueID
} else {
    print("Error: Input device '\(input)' not found.")
    exit(1)
}

if let outDev = model.outputDevices.first(where: { $0.name.localizedCaseInsensitiveContains(output) }) {
    print("Selecting Output: \(outDev.name)")
    model.selectedOutputDeviceID = outDev.id
} else {
    print("Error: Output device '\(output)' not found.")
    exit(1)
}

model.outputGainValue = gain
model.isAIEnabled = true

print("AI Pipeline Active. Press Ctrl+C to stop.")
RunLoop.main.run()
```

Note: `--action` mode requires `import AppKit` (for `NSWorkspace`). Add `import AppKit` at
the top of `main.swift`. The `NoNoiseMacCLI` target links `AppKit` implicitly on macOS;
no `Package.swift` change is needed.

- [ ] **Step 2: Build**

```bash
swift build
```

Expected: build succeeds. The `--action toggle` path calls `NSWorkspace.shared.open(_:)` and
exits; the pipeline path is unchanged.

- [ ] **Step 3: Commit**

```bash
git add Sources/CLI/main.swift
git commit -m "feat(cli): add --action verb to send one-shot control via URL scheme (toggle, bypass, preset-next, etc.)"
```

---

## Task 8: Documentation (8-Fold Awareness Step 2 + compounding)

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md` (the repo's `CLAUDE.md` is a **symlink** to `AGENTS.md` — editing
  `AGENTS.md` updates both; do NOT create a separate `CLAUDE.md`)
- Modify: `docs/knowledge/timeline1.md`
- Modify: `docs/knowledge/knowledge1.md`

> **Doc target note:** `CLAUDE.md` → `AGENTS.md` is a symlink (verified: `ls -la CLAUDE.md`
> shows `CLAUDE.md -> AGENTS.md`). All agent-guide edits go in `AGENTS.md`.

- [ ] **Step 1: `README.md`** — add a section after the "🎙️ Broadcast Voice" bullet (added by the broadcast-voice plan):

```markdown
- **⌨️ Global Hotkeys + Stream Deck** — system-wide hotkeys (user-configurable) for every
  control action (toggle AI, A/B bypass, cycle preset, cycle Broadcast Voice, nudge gain), plus
  a `nonoisemac://` URL scheme for Stream Deck "Open" actions or shell scripting.
```

Add a subsection after the Broadcast Voice subsection:

```markdown
### ⌨️ Global Hotkeys + Stream Deck

**Global hotkeys** (default combos use ⌃⌥ to avoid system-shortcut collisions):

| Action | Default |
|---|---|
| Toggle Noise Cancellation | ⌃⌥N |
| A/B Bypass (hold for raw) | ⌃⌥B |
| A/B Bypass (toggle) | ⌃⌥⇧B |
| Preset → Next | ⌃⌥] |
| Preset → Previous | ⌃⌥[ |
| Broadcast Voice → Next | ⌃⌥C |
| Gain + | ⌃⌥= |
| Gain − | ⌃⌥- |

Rebind any hotkey in **Settings → Hotkeys**. If a combo is already in use by another app,
NoNoise Mac shows a conflict warning and leaves that slot unregistered.

**Stream Deck (no SDK required):** Use the Stream Deck "Open" action (or "Website" in Open
mode) with one of these URLs:

```
nonoisemac://toggle
nonoisemac://bypass
nonoisemac://preset/next
nonoisemac://preset/prev
nonoisemac://clarity/next
nonoisemac://gain/up
nonoisemac://gain/down
```

Or from a terminal / shell script: `open nonoisemac://toggle` (or `NoNoiseMacCLI --action toggle`).

**A/B Bypass:** Hold ⌃⌥B to momentarily hear the raw mic (useful for comparing before/after
during a recording). Release to restore AI. ⌃⌥⇧B toggles bypass on/off persistently.
```

Also update the "How it works" Voice Polish bullet so the documented chain order is the merged,
canonical order (presence + de-esser are part of the chain, not omitted). Find this line:

```markdown
- An optional **Voice Polish** chain (high-pass → shelves → compressor → limiter) adds tone
  and leveling for Podcast/Tutorial modes.
```

and replace it with:

```markdown
- An optional **Voice Polish** chain (high-pass → shelves → presence → de-esser → compressor →
  limiter) adds tone, clarity, and leveling for Podcast/Tutorial modes and Broadcast Voice.
```

- [ ] **Step 2: `AGENTS.md`** — add a new section "Control layer (Tier 4)" after the "Voice polish chain (Tier 2)" section:

```markdown
## Control layer (Tier 4) — `Sources/Core/ControlLayer.swift`, `Sources/App/ActionDispatcher.swift`, `Sources/App/HotkeyManager.swift`

- **Core/App split (so it stays testable):** the PURE models — `ControlAction` (URL/CLI parsers
  + gain constants), `HotkeyActionID`, `HotkeyBinding`, `HotkeyModifier`, `ControlState`, and the
  `ControlReducer` state machine — live in `Sources/Core/ControlLayer.swift` and import only
  `Foundation`. The test target depends on `Core` only, so the REAL dispatch logic (bypass
  transitions, desired-vs-effective AI, gain clamping, cycling) is unit-tested via `ControlReducer`
  (`Tests/NoNoiseMacTests/ControlLayerTests.swift`) WITHOUT constructing `AudioModel`.
- `ActionDispatcher` (@MainActor, App) is a thin adapter: it reads a `ControlState` snapshot from
  `AudioModel`, runs `ControlReducer.reduce`, and writes the result back. It is the single dispatch
  point for all control actions. It is NOT headless-testable (depends on `AudioModel` → CoreAudio).
- **A/B bypass = desired-vs-effective AI.** `desiredAIEnabled` is the user's intended AI on/off
  ignoring bypass; effective = `desiredAI && !(momentary || toggle bypass)`. `.toggleAI` ALWAYS
  flips `desiredAI` (even while bypassed); on bypass exit, `AudioModel.isAIEnabled` follows the
  current desired value. Firing toggle-AI mid-bypass therefore does NOT turn AI back on against the
  bypass. Bypass state is session-only (never persisted); `desiredAI` mirrors the persisted
  `isAIEnabled`. This is the only place `isAIEnabled` is written from outside its `didSet` path.
- `HotkeyManager` (@MainActor, App) uses Carbon `RegisterEventHotKey` + `InstallEventHandler`.
  **Do NOT switch to `NSEvent.addGlobalMonitorForEvents`** — that requires Accessibility permission,
  violating the minimal-entitlement policy (AGENTS.md "Entitlements & signing"). Carbon hotkeys work
  with the existing two entitlements and no permission prompt.
- **Hotkeys register at app launch**, in `NoNoiseMacApp.init()` (HotkeyManager held on `@StateObject`),
  NOT in `ContentView.onAppear` — a `MenuBarExtra`'s content view isn't instantiated until the
  popover opens, so onAppear-registration would leave hotkeys dead until first click.
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
```

> **Voice-chain order in this section / any docs you touch:** use the canonical merged order
> `hp → shelves → presence → deEsser → comp → limiter` (matching the existing "Voice polish chain
> (Tier 2)" entry). Do not document a truncated `hp → shelves → comp → limiter` that omits the
> Broadcast Voice clarity stages.

- [ ] **Step 3: `docs/knowledge/timeline1.md`** — append:

```markdown
## 2026-06-15 — Control layer (global hotkeys + A/B bypass + Stream Deck) added

Added the pure control models + `ControlReducer` to `Sources/Core/ControlLayer.swift`
(`ControlAction`, `HotkeyActionID`, `HotkeyBinding`, `HotkeyModifier`, `ControlState`) so the
real dispatch logic is unit-tested headlessly without `AudioModel`. `ActionDispatcher`
(Sources/App) adapts the reducer onto a live `AudioModel`. `HotkeyManager` (Sources/App)
registers system-wide Carbon `RegisterEventHotKey` combos (default ⌃⌥ set, deterministic
`EventHotKeyID`s) with UserDefaults persistence under `mv.hotkey.*`; created at app launch in
`NoNoiseMacApp.init()` so hotkeys are live before the popover opens. `nonoisemac://` URL scheme
registered in `Resources/Info.plist`. A/B bypass uses a desired-vs-effective AI model: while
bypassed, AI is forced off and toggle-AI updates the DESIRED state (restored on bypass exit) —
never persisted. Gain nudge clamps to the slider's `0.5...4.0`. `NoNoiseMacCLI` extended with
`--action <verb>`.
```

- [ ] **Step 4: `docs/knowledge/knowledge1.md`** — append a `[DECISION]` entry:

```markdown
## 2026-06-15 — [DECISION] Carbon RegisterEventHotKey over NSEvent global monitors (@<username>)

**Problem**: System-wide hotkeys for a backgrounded menu-bar app.
**Decision**: Use Carbon `RegisterEventHotKey` + `InstallEventHandler`. It works under the
hardened runtime with the existing two entitlements (no new entitlement, no Accessibility
prompt). `NSEvent.addGlobalMonitorForEvents` is the SwiftUI-friendly alternative but requires
Accessibility permission — violating the minimal-entitlement policy.
**Rule**: Never add Accessibility permission for hotkey capture in this app. If global key
monitoring is ever needed beyond registered combos, revisit and document the permission impact.
**Files**: `Sources/App/HotkeyManager.swift`, `Resources/NoNoiseMac.entitlements`

## 2026-06-15 — [PATTERN] Pure reducer in Core makes the control layer testable (@<username>)

**Problem**: The test target depends on `Core` only; `AudioModel.init()` starts CoreAudio so it
is not headless-testable. Putting control logic in `Sources/App` (consumed via `@testable import
Core`) would be untestable and would not even compile from tests.
**Decision**: Keep the PURE models + a `ControlReducer` over a value-type `ControlState` in
`Sources/Core/ControlLayer.swift`. `ActionDispatcher` (App) is a thin adapter (read state from
`AudioModel` → reduce → write back). Tests exercise the reducer directly — no test-only branches.
**Rule**: Any control/state logic that must be tested goes in `Core` as a pure function over a
value type; the App layer only adapts it onto live objects. Never put testable logic in `App`.
**Files**: `Sources/Core/ControlLayer.swift`, `Sources/App/ActionDispatcher.swift`,
`Tests/NoNoiseMacTests/ControlLayerTests.swift`

## 2026-06-15 — [GOTCHA] A/B bypass needs desired-vs-effective AI state (@<username>)

**Problem**: Naïvely saving `isAIEnabled` on bypass entry and restoring on exit breaks if the user
toggles AI WHILE bypassed: the toggle flips the forced-off live value, then bypass exit clobbers it
back to the pre-bypass value — the toggle is lost.
**Root Cause**: A single `isAIEnabled` field conflated "what the user wants" with "what's playing".
**Fix**: Separate `desiredAI` (what the user wants, flipped by `.toggleAI` always) from effective AI
(`desiredAI && !bypassed`, written to `AudioModel.isAIEnabled`). Bypass exit recomputes effective
from the CURRENT desired value. See `ControlReducer` + the bypass-sequence tests.
**Rule**: When a transient override (bypass) suppresses a user-settable flag, store the user's
desired value separately and recompute the effective value — don't save/restore the live value.
**Files**: `Sources/Core/ControlLayer.swift`, `Tests/NoNoiseMacTests/ControlLayerTests.swift`

## 2026-06-15 — [GOTCHA] Carbon EventHotKeyID must be deterministic, not hashValue (@<username>)

**Problem**: Building `EventHotKeyID.id` from `action.rawValue.hashValue` makes the fired hotkey
ID un-matchable: Swift's `String.hashValue` is randomized per process, so the value used at
registration differs from naive reconstruction and the event can't be routed back to its action.
**Fix**: Derive the numeric ID from the action's index in `HotkeyActionID.allCases` (+1, never 0).
Also: the Carbon C callback must not call a `@MainActor` method synchronously — extract the
`EventHotKeyID` in the callback, then hop via `Task { @MainActor in … }`.
**Rule**: Carbon `EventHotKeyID`s must be stable, deterministic small integers; bridge C callbacks
to the main actor explicitly instead of assuming the calling thread.
**Files**: `Sources/App/HotkeyManager.swift`
```

- [ ] **Step 5: Commit**

```bash
git add README.md AGENTS.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document control layer (hotkeys, A/B bypass, URL scheme, Stream Deck)"
```

---

## Manual smoke test (after all tasks)

### Prerequisites

```bash
./bundle.sh          # build and sign the .app
open NoNoiseMac.app  # install+open (or ./install-app.sh)
```

### Hotkey tests

0. **Hotkeys live before popover open (regression for the onAppear bug):** Launch the app and DO
   NOT click the menu-bar icon. With focus in another app (e.g. TextEdit), press ⌃⌥N. The menu-bar
   icon must change state (AI off ↔ on) WITHOUT ever opening the popover. If nothing happens until
   the popover is first opened, the HotkeyManager is being created in `ContentView.onAppear` instead
   of `NoNoiseMacApp.init()` — fix Task 3.
1. Open the popover. Confirm **Noise Cancellation** toggle reflects the current state.
2. Press ⌃⌥N (default toggle). Confirm the toggle flips; press again, confirm it flips back.
3. Hold ⌃⌥B — the popover (if open) shows the orange A/B Bypass banner; AI is heard as raw mic.
   Release — banner disappears, AI resumes at its pre-bypass value.
4. Press ⌃⌥⇧B — bypass toggles ON (banner). Press again — bypass toggles OFF.
5. **Desired-vs-effective regression:** With AI ON, hold ⌃⌥B (bypass on, raw mic), and WHILE holding
   press ⌃⌥N (toggle). Release ⌃⌥B. Confirm AI stays OFF (the toggle won) — it must NOT snap back ON.
6. Press ⌃⌥] — preset advances. Press ⌃⌥[ — preset retreats.
7. Press ⌃⌥C — Broadcast Voice clarity cycles.
8. Press ⌃⌥= and ⌃⌥- — observe gain going up/down in Settings; confirm it never exceeds 4.0 or drops below 0.5.

### Settings → Hotkeys tab

9. Open Settings. A **Hotkeys** tab appears.
10. Confirm all 8 bindings are listed with their default combos.
11. Click **Edit** on one binding, press a new combo (e.g. ⌃⌥⇧N), click **Save**.
12. Quit and relaunch — confirm the rebound combo is restored (persistence via `mv.hotkey.*`).
13. Try binding to a combo already in use by another app — confirm the slot shows the conflict warning and the old hotkey no longer fires.

### URL scheme (Stream Deck path)

> URL-scheme registration only works in the bundled `.app` — not in `swift run`.

14. With `NoNoiseMac.app` running: `open nonoisemac://toggle` in Terminal. Confirm AI toggles.
15. `open nonoisemac://bypass` — confirm bypass activates (orange banner if popover is open).
16. `open nonoisemac://preset/next` — confirm preset cycles.
17. `open nonoisemac://clarity/next` — confirm Broadcast Voice cycles.
18. `open nonoisemac://gain/up` — confirm gain increases.
19. **Stream Deck:** Add a "Open" button → URL → `nonoisemac://toggle`. Press the button on the Stream Deck. Confirm AI toggles.

### CLI action mode

20. (Requires the `.app` to be running and registered): `./NoNoiseMacCLI --action toggle` — confirm AI toggles.
21. `./NoNoiseMacCLI --action preset-next` — confirm preset cycles.
22. `./NoNoiseMacCLI --help` — confirm the Stream Deck URL reference and verb list are printed.

### Persistence

23. Set a non-default preset, toggle bypass, quit and relaunch. Confirm:
    - Preset restored correctly.
    - Bypass is NOT restored (it is session-only, not persisted).
    - `isAIEnabled` is restored to its desired (pre-bypass) value — the persisted preference is correct because bypass never persists, and `desiredAI` mirrors it.

### Regression

24. With all features off (AI on, default preset, clarity off, no bypass), confirm the audio output is byte-for-byte equivalent to a build without this feature (the control layer only dispatches; it has no DSP path of its own).

---

## Self-Review (completed during authoring)

- **Entitlement impact:** Zero. Carbon `RegisterEventHotKey` works with the existing two keys.
  No third key added. `nonoisemac://` URL scheme is a `Info.plist` declaration, not an
  entitlement. `NSEvent` global monitors are explicitly NOT used.
- **Hotkey API choice documented:** Carbon vs NSEvent tradeoff explained in context section,
  in `HotkeyManager.swift` inline comment, and in `AGENTS.md`. No ambiguity left for future agents.
- **URL-scheme SwiftPM caveat documented:** Task 4 Step 3 note + smoke test calls it out.
  `swift run` will NOT register the scheme; only the bundled `.app` will.
- **A/B bypass = desired-vs-effective:** `desiredAI` is separate from effective AI; `.toggleAI`
  always flips desired (even while bypassed); bypass exit recomputes effective from current desired.
  Bypass is session-only. Verified by `ControlReducer` tests (bypass↓→toggle→bypass↑, overlap,
  bypass+preset) and smoke-test steps 5 + 23.
- **Testability (reviewer fix #1/#6):** the pure models + `ControlReducer` live in `Sources/Core`
  (test target depends on `Core` only) and the REAL dispatch logic is unit-tested via the reducer —
  no `AudioModel`, no test-only branches. `HotkeyBinding` stores a plain `UInt32` mask, adapted to
  `NSEvent.ModifierFlags` only at the App boundary.
- **Launch-time hotkey registration (reviewer fix #2):** `HotkeyManager` is created in
  `NoNoiseMacApp.init()` (held on `@StateObject`), not in `ContentView.onAppear` — hotkeys are live
  before the popover is ever opened. Smoke-test step 0 guards this.
- **Compilation correctness (reviewer fix #3):** `ActionDispatcher` + `HotkeyManager` both conform
  to `ObservableObject`; `import AppKit`/`Combine`/`Carbon.HIToolbox` present; the Carbon C callback
  hops to the main actor via `Task { @MainActor in … }`; `EventHotKeyID`s are deterministic
  (`allCases` index + 1), not `hashValue`.
- **Gain bounds (reviewer fix #7):** clamp range is `0.5...4.0`, matching the Settings slider.
- **`mv.*` namespace preserved:** All new persistence keys use `mv.hotkey.*` (consistent with
  the existing `mv.preset`, `mv.suppressionStrength`, etc.).
- **No MetalVoice/Ghostkwebb in Sources/:** New files are `Sources/Core/ControlLayer.swift`,
  `Sources/App/ActionDispatcher.swift`, `Sources/App/HotkeyManager.swift` — all branded identifiers.
- **Render thread untouched:** `ActionDispatcher.dispatch` writes to `AudioModel`'s
  `@Published` properties on the main thread — the same pattern as the existing `outputGainValue`
  knob. No new lock or synchronisation primitive needed.
- **Docs target (reviewer fix #8):** agent-guide edits go in `AGENTS.md` (`CLAUDE.md` is its
  symlink); voice-chain order documented as the merged `hp → shelves → presence → deEsser → comp →
  limiter`.
- **Threading completeness (reviewer fix #5):** Task 5 updates `SettingsView`, `WindowManager.openSettings`,
  the `ContentView` property, and BOTH `openSettings` call sites in one commit (`SettingsView.swift`
  + `ContentView.swift`).
- **Placeholder scan:** No placeholders. All code shown is complete and copy-pasteable.
- **Type consistency:** `ControlAction`, `ControlReducer`, `ControlState`, `HotkeyBinding`,
  `HotkeyActionID`, `HotkeyModifier`, `HotkeyManager`, `ActionDispatcher`, `KeyCaptureView`,
  `RebindSheet`, `HotkeySettingsView` used consistently across tasks. `HotkeyActionID` conforms to
  `Identifiable` in the UI task where needed.
