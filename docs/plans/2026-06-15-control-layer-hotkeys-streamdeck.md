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

**Architecture:** A new `Sources/App/ActionDispatcher.swift` coordinator sits between
`AudioModel` (the Core state machine) and all external triggers. `AudioModel` itself gains
**no knowledge** of hotkeys or URL schemes — all that wiring lives in App. This keeps the Core
target free of `Carbon` / `AppKit`-specific imports and fully unit-testable.

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
| `gainUp` | `outputGainValue += 0.1` (clamped to 2.0) | |
| `gainDown` | `outputGainValue -= 0.1` (clamped to 0.0) | |

**Safety from a backgrounded global hotkey or URL open:** All these writes go to
`AudioModel`'s `@Published` properties on the main thread. `DispatchQueue.main.async` is
always used in `ActionDispatcher.dispatch(_:)`. The render callback reads plain `Float`/`Bool`
scalars (lock-free on arm64) or checks `isAIEnabled` inside the audio thread — exactly the
existing pattern for `outputGain` etc. No additional synchronization is needed.

### A/B bypass design

"Hear raw" is a single `isBypassed: Bool` property on `ActionDispatcher` (not persisted).
When `true`, `AudioModel.isAIEnabled` is shadowed to `false` (pass raw mic through), but the
underlying persisted `isAIEnabled` preference is unchanged. On bypass release, AI is restored
to whatever it was before bypass.

Two gestures:
- **Momentary (hold):** Hotkey down → bypass on; hotkey up → bypass off. Carbon supplies
  separate `EventHotKeyPressed` / `EventHotKeyReleased` events. The default bypass key is
  mapped to the momentary path.
- **Toggle:** One additional `bypassToggle` action ID. Both can be hotkey-bound.

`isBypassedMomentary` and `isBypassedToggle` are tracked separately; effective bypass =
`isBypassedMomentary || isBypassedToggle`.

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
  `NoNoiseMacTests` test target. Swift tools version 5.9, macOS 13+.
- `Tests/NoNoiseMacTests/`: headless, no CoreAudio/CoreML. `@testable import Core`.
- `VoicePreset`: `CaseIterable`; cases can be cycled via `allCases` index arithmetic.
- `ClarityLevel`: `CaseIterable`; same cycling pattern (added by broadcast-voice plan).

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch**

```bash
git checkout -b feat/control-layer-hotkeys-streamdeck
```

Expected: `Switched to a new branch 'feat/control-layer-hotkeys-streamdeck'`. Use
`git add <specific files>` in every commit — never `git add -A` or `.`.

---

## Task 1: `ActionDispatcher` + `ControlAction` — unit-testable core — TDD

Define the typed action enum, the A/B bypass state machine, and the dispatcher that routes
actions to `AudioModel`. All logic that doesn't touch Carbon or AppKit lives here so it can
be unit-tested headlessly.

**Files:**
- Create: `Sources/App/ActionDispatcher.swift`
- Create: `Tests/NoNoiseMacTests/ActionDispatcherTests.swift`

### Step 1: Write the failing tests

Create `Tests/NoNoiseMacTests/ActionDispatcherTests.swift`:

```swift
import XCTest
@testable import Core

/// Tests the pure ControlAction enum and ControlAction.from(url:) parser.
/// ActionDispatcher itself cannot be tested headlessly (it depends on AudioModel
/// which starts CoreAudio), but its URL parser and action enum are pure.
final class ControlActionTests: XCTestCase {

    // MARK: - URL parsing

    func testToggleURLParsed() {
        let url = URL(string: "nonoisemac://toggle")!
        XCTAssertEqual(ControlAction.from(url: url), .toggleAI)
    }

    func testBypassURLParsed() {
        let url = URL(string: "nonoisemac://bypass")!
        XCTAssertEqual(ControlAction.from(url: url), .bypassToggle)
    }

    func testPresetNextURLParsed() {
        let url = URL(string: "nonoisemac://preset/next")!
        XCTAssertEqual(ControlAction.from(url: url), .presetNext)
    }

    func testPresetPrevURLParsed() {
        let url = URL(string: "nonoisemac://preset/prev")!
        XCTAssertEqual(ControlAction.from(url: url), .presetPrev)
    }

    func testClarityNextURLParsed() {
        let url = URL(string: "nonoisemac://clarity/next")!
        XCTAssertEqual(ControlAction.from(url: url), .clarityNext)
    }

    func testGainUpURLParsed() {
        let url = URL(string: "nonoisemac://gain/up")!
        XCTAssertEqual(ControlAction.from(url: url), .gainUp)
    }

    func testGainDownURLParsed() {
        let url = URL(string: "nonoisemac://gain/down")!
        XCTAssertEqual(ControlAction.from(url: url), .gainDown)
    }

    func testUnknownURLReturnsNil() {
        let url = URL(string: "nonoisemac://unknown/verb")!
        XCTAssertNil(ControlAction.from(url: url))
    }

    func testWrongSchemeReturnsNil() {
        let url = URL(string: "https://example.com/toggle")!
        XCTAssertNil(ControlAction.from(url: url))
    }

    // MARK: - CLI verb parsing

    func testCLIVerbToggle() {
        XCTAssertEqual(ControlAction.from(cliVerb: "toggle"), .toggleAI)
    }

    func testCLIVerbBypass() {
        XCTAssertEqual(ControlAction.from(cliVerb: "bypass"), .bypassToggle)
    }

    func testCLIVerbPresetNext() {
        XCTAssertEqual(ControlAction.from(cliVerb: "preset-next"), .presetNext)
    }

    func testCLIVerbPresetPrev() {
        XCTAssertEqual(ControlAction.from(cliVerb: "preset-prev"), .presetPrev)
    }

    func testCLIVerbClarityNext() {
        XCTAssertEqual(ControlAction.from(cliVerb: "clarity-next"), .clarityNext)
    }

    func testCLIVerbGainUp() {
        XCTAssertEqual(ControlAction.from(cliVerb: "gain-up"), .gainUp)
    }

    func testCLIVerbGainDown() {
        XCTAssertEqual(ControlAction.from(cliVerb: "gain-down"), .gainDown)
    }

    func testCLIVerbUnknownReturnsNil() {
        XCTAssertNil(ControlAction.from(cliVerb: "explode"))
    }

    // MARK: - Preset cycling (pure index math on VoicePreset.allCases)

    func testPresetCycleForwardWraps() {
        // Cycling forward from the last case should wrap to the first.
        let cases = VoicePreset.allCases
        guard let last = cases.last, let first = cases.first else { return XCTFail() }
        let nextIdx = (cases.count - 1 + 1) % cases.count
        XCTAssertEqual(cases[nextIdx], first,
                       "cycling past last preset must wrap to first")
        // And from the first, one step forward is the second.
        XCTAssertEqual(cases[(0 + 1) % cases.count], cases[1])
        _ = last // silence "unused" warning
    }

    func testPresetCycleBackwardWraps() {
        let cases = VoicePreset.allCases
        guard let first = cases.first else { return XCTFail() }
        let prevIdx = (0 - 1 + cases.count) % cases.count
        XCTAssertEqual(cases[prevIdx], cases.last!,
                       "cycling before first preset must wrap to last")
        _ = first
    }

    // MARK: - Clarity cycling (pure index math on ClarityLevel.allCases)

    func testClarityCycleForwardWraps() {
        let cases = ClarityLevel.allCases
        XCTAssertEqual(cases[(cases.count - 1 + 1) % cases.count], cases[0],
                       "cycling past .high must wrap to .off")
    }

    // MARK: - Gain clamping constants

    func testGainStepIsPositive() {
        XCTAssertGreaterThan(ControlAction.gainStep, 0)
    }

    func testGainBoundsAreOrdered() {
        XCTAssertLessThan(ControlAction.gainMin, ControlAction.gainMax)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ControlActionTests
```

Expected: compile error — `cannot find type 'ControlAction' in scope`.

- [ ] **Step 3: Implement `ControlAction` and `ActionDispatcher`**

Create `Sources/App/ActionDispatcher.swift`:

```swift
import Foundation
import Core

// MARK: - ControlAction

/// Every user-facing action the control layer can fire. All actions are dispatched
/// to AudioModel on the main thread — they are safe to call from hotkey callbacks,
/// URL opens, or CLI verbs. The enum is in App (not Core) because the URL/CLI
/// parsing depends on string literals that belong to the integration surface, not
/// the audio engine.
public enum ControlAction: Equatable {
    case toggleAI
    case bypassMomentaryDown   // hotkey held — activate momentary bypass
    case bypassMomentaryUp     // hotkey released — deactivate momentary bypass
    case bypassToggle          // URL/CLI path — flip persisted bypass toggle
    case presetNext
    case presetPrev
    case clarityNext
    case gainUp
    case gainDown

    // Gain nudge and clamp values (named constants, testable).
    public static let gainStep: Float = 0.1
    public static let gainMin: Float = 0.0
    public static let gainMax: Float = 2.0

    // MARK: - URL parsing

    /// Parse a `nonoisemac://` URL into a `ControlAction`. Returns nil for unknown
    /// schemes or verbs so callers can silently ignore unrecognised links.
    public static func from(url: URL) -> ControlAction? {
        guard url.scheme?.lowercased() == "nonoisemac" else { return nil }
        // host = first path component in custom-scheme URLs; pathComponents = the rest.
        // e.g. nonoisemac://preset/next → host="preset", path="/next"
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

    // MARK: - CLI verb parsing

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

// MARK: - ActionDispatcher

/// Routes `ControlAction`s to `AudioModel`. Owns the A/B bypass state and must
/// be held as long as the app is alive. All methods must be called from the main
/// thread; callers from other threads must dispatch to `DispatchQueue.main`.
@MainActor
public final class ActionDispatcher: ObservableObject {

    private weak var model: AudioModel?

    // A/B bypass state — NOT persisted.
    // Effective bypass = momentary OR toggle. We shadow isAIEnabled while bypassed
    // (the underlying stored preference is unchanged).
    private var isBypassedMomentary: Bool = false
    private var isBypassedToggle: Bool = false
    private var aiEnabledBeforeBypass: Bool = true   // saved on bypass entry

    @Published public private(set) var isBypassed: Bool = false

    public init(model: AudioModel) {
        self.model = model
    }

    // MARK: - Dispatch

    public func dispatch(_ action: ControlAction) {
        guard let model = model else { return }
        switch action {
        case .toggleAI:
            model.isAIEnabled.toggle()

        case .bypassMomentaryDown:
            if !isBypassedMomentary && !isBypassedToggle {
                aiEnabledBeforeBypass = model.isAIEnabled
            }
            isBypassedMomentary = true
            refreshBypass(model: model)

        case .bypassMomentaryUp:
            isBypassedMomentary = false
            refreshBypass(model: model)

        case .bypassToggle:
            if !isBypassedMomentary && !isBypassedToggle {
                aiEnabledBeforeBypass = model.isAIEnabled
            }
            isBypassedToggle.toggle()
            refreshBypass(model: model)

        case .presetNext:
            let cases = VoicePreset.allCases
            guard let idx = cases.firstIndex(of: model.selectedPreset) else { return }
            model.selectedPreset = cases[(idx + 1) % cases.count]

        case .presetPrev:
            let cases = VoicePreset.allCases
            guard let idx = cases.firstIndex(of: model.selectedPreset) else { return }
            model.selectedPreset = cases[(idx - 1 + cases.count) % cases.count]

        case .clarityNext:
            let cases = ClarityLevel.allCases
            guard let idx = cases.firstIndex(of: model.clarityLevel) else { return }
            model.clarityLevel = cases[(idx + 1) % cases.count]

        case .gainUp:
            model.outputGainValue = min(model.outputGainValue + ControlAction.gainStep, ControlAction.gainMax)

        case .gainDown:
            model.outputGainValue = max(model.outputGainValue - ControlAction.gainStep, ControlAction.gainMin)
        }
    }

    // MARK: - A/B bypass helpers

    private func refreshBypass(model: AudioModel) {
        let nowBypassed = isBypassedMomentary || isBypassedToggle
        if nowBypassed {
            model.isAIEnabled = false
        } else {
            model.isAIEnabled = aiEnabledBeforeBypass
        }
        isBypassed = nowBypassed
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
swift test --filter ControlActionTests
```

Expected: all tests PASS. Note: `ActionDispatcher` itself is in the `App` target, which is
not imported by the test target. Only `ControlAction` (which includes the pure URL and CLI
parsers and the gain constants) is tested headlessly — that is intentional and consistent
with how `AudioModel` tests work in this codebase.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/ActionDispatcher.swift Tests/NoNoiseMacTests/ActionDispatcherTests.swift
git commit -m "feat(control): add ControlAction enum + ActionDispatcher (URL/CLI parsers, A/B bypass)"
```

---

## Task 2: `HotkeyBinding` + `HotkeyManager` — Carbon registration — TDD

Define the persisted hotkey-binding model (key + modifiers per action) and the Carbon
registration layer. The binding model is pure (unit-testable); the Carbon registration is
app-only.

**Files:**
- Create: `Sources/App/HotkeyManager.swift`
- Modify: `Tests/NoNoiseMacTests/ActionDispatcherTests.swift` (add binding tests)

### Step 1: Write the failing tests — add inside `ControlActionTests`

```swift
    // MARK: - HotkeyBinding (pure model)

    /// A binding round-trips through its UserDefaults representation (rawValue).
    func testHotkeyBindingRoundTrip() {
        let b = HotkeyBinding(keyCode: 0x00, modifiers: [.command, .shift])
        let encoded = b.encoded
        let decoded = HotkeyBinding(encoded: encoded)
        XCTAssertEqual(decoded?.keyCode, b.keyCode)
        XCTAssertEqual(decoded?.modifiers, b.modifiers)
    }

    /// A binding with no modifiers still round-trips.
    func testHotkeyBindingNoModifiersRoundTrip() {
        let b = HotkeyBinding(keyCode: 0x24, modifiers: [])
        XCTAssertNotNil(HotkeyBinding(encoded: b.encoded))
    }

    /// Default bindings cover all registered action IDs and are distinct.
    func testDefaultBindingsExistAndAreDistinct() {
        let defaults = HotkeyBinding.defaults
        // Each registered action must have a default.
        let registered: [HotkeyActionID] = [.toggleAI, .bypassMomentary, .bypassToggle,
                                             .presetNext, .presetPrev, .clarityNext,
                                             .gainUp, .gainDown]
        for id in registered {
            XCTAssertNotNil(defaults[id], "missing default for \(id)")
        }
        // All defaults must be distinct combos (no collision at startup).
        let combos = defaults.values.map { "\($0.keyCode)-\($0.modifiers.rawValue)" }
        XCTAssertEqual(Set(combos).count, combos.count, "default hotkey combos must be distinct")
    }

    /// `HotkeyActionID` raw values use the `mv.hotkey.*` namespace.
    func testHotkeyActionIDNamespace() {
        for id in HotkeyActionID.allCases {
            XCTAssertTrue(id.prefKey.hasPrefix("mv.hotkey."),
                          "pref key must use mv.hotkey.* namespace: \(id.prefKey)")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter ControlActionTests
```

Expected: compile error — `cannot find type 'HotkeyBinding' in scope`.

- [ ] **Step 3: Implement `HotkeyManager.swift`**

Create `Sources/App/HotkeyManager.swift`:

```swift
import Foundation
import Carbon.HIToolbox

// MARK: - HotkeyActionID

/// The set of actions that can have a hotkey. Raw value is the UserDefaults key
/// (under the mv.* namespace to match existing persistence conventions).
public enum HotkeyActionID: String, CaseIterable {
    case toggleAI       = "mv.hotkey.toggleAI"
    case bypassMomentary = "mv.hotkey.bypassMomentary"
    case bypassToggle   = "mv.hotkey.bypassToggle"
    case presetNext     = "mv.hotkey.presetNext"
    case presetPrev     = "mv.hotkey.presetPrev"
    case clarityNext    = "mv.hotkey.clarityNext"
    case gainUp         = "mv.hotkey.gainUp"
    case gainDown       = "mv.hotkey.gainDown"

    /// UserDefaults key for this binding.
    public var prefKey: String { rawValue }
}

// MARK: - HotkeyBinding

/// A key-code + modifier mask pair. Stored and restored as a compact string
/// "<keyCode>:<modifierRawValue>" in UserDefaults so no JSON/Codable overhead.
public struct HotkeyBinding: Equatable {
    /// Virtual key code (Carbon kVK_* constants, e.g. kVK_ANSI_N = 0x2D).
    public let keyCode: UInt32
    /// NSEvent-style modifier flags subset: command (1<<20), shift (1<<17), option (1<<19),
    /// control (1<<18). Stored as a raw UInt32.
    public let modifiers: NSEventModifierMask

    public init(keyCode: UInt32, modifiers: NSEventModifierMask) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: Persistence

    /// Compact string encoding: "<keyCode>:<modifiersRawValue>".
    public var encoded: String { "\(keyCode):\(modifiers.rawValue)" }

    /// Decode from the compact string. Returns nil if malformed.
    public init?(encoded: String) {
        let parts = encoded.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let kc = UInt32(parts[0]),
              let mod = UInt(parts[1]) else { return nil }
        keyCode = kc
        modifiers = NSEventModifierMask(rawValue: mod)
    }

    // MARK: Defaults

    /// Default hotkey bindings. Sane starting combos that avoid conflicts with common
    /// macOS system shortcuts. All use ⌃⌥ (Control+Option) as the base modifier, which
    /// is less likely to collide with app shortcuts than ⌘ combos.
    ///
    /// Users can rebind in Settings. These are only the startup defaults; they are written
    /// to UserDefaults on first launch and never overwritten by an update.
    public static let defaults: [HotkeyActionID: HotkeyBinding] = [
        // ⌃⌥N — toggle Noise Cancellation
        .toggleAI:        HotkeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: [.control, .option]),
        // ⌃⌥B — momentary bypass (hold down for raw; release restores AI)
        .bypassMomentary: HotkeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: [.control, .option]),
        // ⌃⌥⇧B — bypass toggle (latching)
        .bypassToggle:    HotkeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: [.control, .option, .shift]),
        // ⌃⌥] — next preset
        .presetNext:      HotkeyBinding(keyCode: UInt32(kVK_ANSI_RightBracket), modifiers: [.control, .option]),
        // ⌃⌥[ — previous preset
        .presetPrev:      HotkeyBinding(keyCode: UInt32(kVK_ANSI_LeftBracket), modifiers: [.control, .option]),
        // ⌃⌥C — cycle Broadcast Voice clarity level
        .clarityNext:     HotkeyBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: [.control, .option]),
        // ⌃⌥= — gain up
        .gainUp:          HotkeyBinding(keyCode: UInt32(kVK_ANSI_Equal), modifiers: [.control, .option]),
        // ⌃⌥- — gain down
        .gainDown:        HotkeyBinding(keyCode: UInt32(kVK_ANSI_Minus), modifiers: [.control, .option]),
    ]
}

// Alias so the test target can use the AppKit type by name without importing AppKit.
typealias NSEventModifierMask = NSEvent.ModifierFlags

// MARK: - HotkeyManager

/// Registers and manages system-wide Carbon hotkeys. Must be created and retained
/// for the lifetime of the app. All methods run on the main thread.
///
/// **Why Carbon `RegisterEventHotKey` and not `NSEvent.addGlobalMonitorForEvents`:**
/// Carbon hotkeys work under the hardened runtime with the existing two entitlements
/// (audio-input + allow-jit) and require NO additional permissions. NSEvent global
/// monitors require Accessibility permission (a user-visible prompt) — which we
/// deliberately avoid to keep the entitlement surface minimal.
@MainActor
public final class HotkeyManager {

    private var dispatcher: ActionDispatcher
    private var registrations: [HotkeyActionID: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// Current active bindings (loaded from UserDefaults or defaults).
    private(set) var bindings: [HotkeyActionID: HotkeyBinding] = [:]
    /// Action IDs whose preferred binding collided with another app.
    @Published public private(set) var conflictedActions: Set<HotkeyActionID> = []

    public init(dispatcher: ActionDispatcher) {
        self.dispatcher = dispatcher
        loadBindings()
        installEventHandler()
        registerAll()
    }

    deinit {
        unregisterAll()
        if let h = eventHandler { RemoveEventHandler(h) }
    }

    // MARK: - Public API

    /// Update the binding for a single action: unregisters the old combo, persists
    /// the new one, and re-registers. Returns true if registration succeeded.
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
            if let raw = d.string(forKey: id.prefKey),
               let b = HotkeyBinding(encoded: raw) {
                bindings[id] = b
            } else {
                // First launch: write and use the default.
                if let def = HotkeyBinding.defaults[id] {
                    bindings[id] = def
                    d.set(def.encoded, forKey: id.prefKey)
                }
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
        for (id, binding) in bindings {
            register(action: id, binding: binding)
        }
    }

    @discardableResult
    private func register(action: HotkeyActionID, binding: HotkeyBinding) -> Bool {
        let carbonMods = carbonModifiers(from: binding.modifiers)
        var hotKeyID = EventHotKeyID(signature: fourCC("NoNM"), id: UInt32(action.rawValue.hashValue & 0x7FFFFFFF))
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(binding.keyCode, carbonMods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
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
        if let ref = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    private func unregisterAll() {
        for (_, ref) in registrations { UnregisterEventHotKey(ref) }
        registrations.removeAll()
    }

    // MARK: - Event dispatch

    /// Called by the Carbon event handler (C shim below). Identifies the action by
    /// matching the fired EventHotKeyID back to a registered registration slot.
    fileprivate func handleHotKeyEvent(_ event: EventRef, pressed: Bool) {
        var hotkeyID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
        // Find which action owns this ID by matching signature + numeric ID.
        for (actionID, binding) in bindings {
            let expected = UInt32(actionID.rawValue.hashValue & 0x7FFFFFFF)
            guard hotkeyID.id == expected else { continue }
            if pressed {
                switch actionID {
                case .bypassMomentary:
                    dispatcher.dispatch(.bypassMomentaryDown)
                default:
                    dispatcher.dispatch(ControlAction.from(cliVerb: actionID.cliVerb) ?? .toggleAI)
                }
            } else {
                // Key released — only momentary bypass cares.
                if actionID == .bypassMomentary {
                    dispatcher.dispatch(.bypassMomentaryUp)
                }
            }
            return
        }
    }

    // MARK: - Helpers

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    private func fourCC(_ s: String) -> OSType {
        let bytes = Array(s.utf8)
        guard bytes.count >= 4 else { return 0 }
        return OSType(bytes[0]) << 24 | OSType(bytes[1]) << 16 | OSType(bytes[2]) << 8 | OSType(bytes[3])
    }
}

// MARK: - Carbon event handler (C-compatible function)

/// Top-level C callback required by `InstallEventHandler`. Bridges to the Swift
/// `HotkeyManager.handleHotKeyEvent` method via the stored `userData` pointer.
private func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    // The handler is always called on the main thread by Carbon (menu-bar app context).
    manager.handleHotKeyEvent(event, pressed: pressed)
    return noErr
}

// MARK: - HotkeyActionID CLI verb mapping

private extension HotkeyActionID {
    var cliVerb: String {
        switch self {
        case .toggleAI:        return "toggle"
        case .bypassMomentary: return "bypass"  // momentary; mapped internally
        case .bypassToggle:    return "bypass"
        case .presetNext:      return "preset-next"
        case .presetPrev:      return "preset-prev"
        case .clarityNext:     return "clarity-next"
        case .gainUp:          return "gain-up"
        case .gainDown:        return "gain-down"
        }
    }
}
```

- [ ] **Step 4: Run the full test suite**

```bash
swift test
```

Expected: all tests PASS (existing suite + new `ControlActionTests` binding tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/App/HotkeyManager.swift Tests/NoNoiseMacTests/ActionDispatcherTests.swift
git commit -m "feat(hotkeys): add HotkeyBinding model + Carbon HotkeyManager (mv.hotkey.* namespace)"
```

---

## Task 3: Wire `ActionDispatcher` + `HotkeyManager` into the app lifecycle

`NoNoiseMacApp` creates both, passes them into `ContentView`, and registers the URL-scheme
handler. `AppDelegate` gets a `application(_:open:)` fallback. No new entitlements.

**Files:**
- Modify: `Sources/App/NoNoiseMacApp.swift`

- [ ] **Step 1: Update `NoNoiseMacApp.swift`**

Replace the entire file content with:

```swift
import SwiftUI
import Core

@main
struct NoNoiseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var audioModel = AudioModel()

    // ActionDispatcher and HotkeyManager are created once and live for the app's
    // lifetime. HotkeyManager MUST be retained (Carbon hotkeys are unregistered on
    // deinit) — storing it on @StateObject keeps it alive.
    @StateObject private var dispatcher: ActionDispatcher
    // HotkeyManager holds an unretained reference to dispatcher. It must be created
    // AFTER dispatcher. We use a lazy wrapper via onAppear to avoid the init-order
    // problem with @StateObject cross-reference.
    @State private var hotkeyManager: HotkeyManager?

    init() {
        // @StateObject requires initialising via _wrappedValue on init; AudioModel
        // is created first, then ActionDispatcher wraps it.
        let model = AudioModel()
        _audioModel = StateObject(wrappedValue: model)
        _dispatcher = StateObject(wrappedValue: ActionDispatcher(model: model))
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(audioModel: audioModel, dispatcher: dispatcher)
                .onAppear {
                    if hotkeyManager == nil {
                        hotkeyManager = HotkeyManager(dispatcher: dispatcher)
                        appDelegate.dispatcher = dispatcher
                    }
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

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by NoNoiseMacApp after the first onAppear.
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

- [ ] **Step 2: Build**

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/NoNoiseMacApp.swift
git commit -m "feat(app): wire ActionDispatcher + HotkeyManager into app lifecycle, URL open handler"
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

Add a **Hotkeys** tab (or section within Settings) to `SettingsView` so users can see
current bindings and rebind any action. A conflict warning is shown for collided slots.

**Files:**
- Modify: `Sources/App/SettingsView.swift`

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
        let m = b.modifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        // Map common kVK codes to printable glyphs (non-exhaustive — covers the default set).
        let keyGlyphs: [UInt32: String] = [
            0x2D: "N", 0x0B: "B", 0x1E: "]", 0x21: "[", 0x08: "C",
            0x18: "=", 0x1B: "-",
        ]
        s += keyGlyphs[b.keyCode] ?? "?\(b.keyCode)"
        return s
    }
}

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
        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode),
                                    modifiers: event.modifierFlags.intersection([.command, .option, .shift, .control]))
        onCapture?(binding)
    }
}
```

- [ ] **Step 2: Add a Hotkeys tab to the top-level `SettingsView`**

In `Sources/App/SettingsView.swift`, find the existing `TabView` (or `SettingsView` body)
and add a Hotkeys tab after the General tab:

```swift
TabView {
    GeneralSettingsView(audioModel: audioModel)
        .tabItem { Label("General", systemImage: "slider.horizontal.3") }
    HotkeySettingsView(manager: hotkeyManager)
        .tabItem { Label("Hotkeys", systemImage: "keyboard") }
}
```

The `hotkeyManager` reference must be threaded from `ContentView` → `WindowManager.openSettings`
→ `SettingsView`. Update `WindowManager.openSettings(model:)` to accept an additional
`hotkeyManager: HotkeyManager` parameter and update all call sites in `ContentView.swift`
and `NoNoiseMacApp.swift`.

- [ ] **Step 3: Build**

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```swift
git add Sources/App/SettingsView.swift
git commit -m "feat(ui): add Hotkeys settings tab with rebind sheet and conflict warnings"
```

---

## Task 6: A/B Bypass UI indicator in the menu-bar popover

Show a transient "A/B Bypass — hearing raw mic" banner in `ContentView` when bypass is
active, so the user knows they are in passthrough mode.

**Files:**
- Modify: `Sources/App/ContentView.swift`

No XCTest — build + manual.

- [ ] **Step 1: Thread `dispatcher` into `ContentView`**

Add `@ObservedObject var dispatcher: ActionDispatcher` as a property of `ContentView`.
Update the `ContentView(audioModel:)` call site in `NoNoiseMacApp.swift` to pass
`dispatcher: dispatcher` (already handled in Task 3).

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
- Modify: `AGENTS.md`
- Modify: `docs/knowledge/timeline1.md`
- Modify: `docs/knowledge/knowledge1.md`

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

- [ ] **Step 2: `AGENTS.md`** — add a new section "Control layer (Tier 4)" after the "Voice polish chain (Tier 2)" section:

```markdown
## Control layer (Tier 4) — `Sources/App/ActionDispatcher.swift`, `HotkeyManager.swift`

- `ActionDispatcher` (@MainActor) is the single dispatch point for all user-initiated
  control actions (`ControlAction` enum). It owns the A/B bypass state (`isBypassedMomentary`
  / `isBypassedToggle`). All action dispatches to `AudioModel` happen on the main thread.
- `HotkeyManager` (@MainActor) uses Carbon `RegisterEventHotKey` + `InstallEventHandler`.
  **Do NOT switch to `NSEvent.addGlobalMonitorForEvents`** — that requires Accessibility
  permission, which violates the minimal-entitlement policy (AGENTS.md "Entitlements & signing").
  Carbon hotkeys work with the existing two entitlements and no permission prompt.
- Bindings are persisted under `mv.hotkey.*` keys in `UserDefaults` (consistent with the
  existing `mv.*` namespace). `HotkeyBinding` encodes as `"<keyCode>:<modifierRawValue>"`.
- If `RegisterEventHotKey` returns `eventHotKeyExistsErr` (-9878), the slot is left
  unregistered and surfaced in `conflictedActions` (shown in Settings → Hotkeys). Never crash.
- A/B bypass shadows `AudioModel.isAIEnabled` WITHOUT persisting the change — when bypass
  is released, the original `isAIEnabled` preference is restored. This is the only place where
  `isAIEnabled` is written from outside its `didSet` persistence path.
- `nonoisemac://` URL scheme is registered in `Resources/Info.plist` (`CFBundleURLTypes`).
  **This only works in a bundled `.app`** — `swift run` / `swift build` do not register URL
  schemes. Test via `./bundle.sh` + opening `NoNoiseMac.app`.
- `ControlAction` (URL/CLI parsers + gain constants) lives in the `App` target and IS
  unit-testable headlessly (`Tests/NoNoiseMacTests/ActionDispatcherTests.swift`). The Carbon
  registration and SwiftUI wiring are NOT tested headlessly (same policy as `AudioModel`).
```

- [ ] **Step 3: `docs/knowledge/timeline1.md`** — append:

```markdown
## 2026-06-15 — Control layer (global hotkeys + A/B bypass + Stream Deck) added

Added `ActionDispatcher` + `ControlAction` (Sources/App) for all user-facing control
actions (toggle AI, A/B bypass momentary/toggle, cycle preset, cycle clarity, nudge gain).
`HotkeyManager` registers system-wide Carbon `RegisterEventHotKey` combos (default ⌃⌥
modifier set) with UserDefaults persistence under `mv.hotkey.*`. `nonoisemac://` URL scheme
registered in `Resources/Info.plist` for Stream Deck "Open" / `open` CLI. A/B bypass
shadows `isAIEnabled` without persisting. `NoNoiseMacCLI` extended with `--action <verb>`.
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

1. Open the popover. Confirm **Noise Cancellation** toggle is ON.
2. Press ⌃⌥N (default toggle). Confirm the toggle flips OFF; press again, confirm ON.
3. Hold ⌃⌥B — the popover (if open) should show the orange A/B Bypass banner. Release — banner disappears, AI resumes.
4. Press ⌃⌥⇧B — bypass toggles ON (banner). Press again — bypass toggles OFF.
5. Press ⌃⌥] — preset advances. Press ⌃⌥[ — preset retreats.
6. Press ⌃⌥C — Broadcast Voice clarity cycles.
7. Press ⌃⌥= and ⌃⌥- — observe gain going up/down in Settings (or check `outputGainValue` behavior).

### Settings → Hotkeys tab

8. Open Settings. A **Hotkeys** tab appears.
9. Confirm all 8 bindings are listed with their default combos.
10. Click **Edit** on one binding, press a new combo (e.g. ⌃⌥⇧N), click **Save**.
11. Quit and relaunch — confirm the rebound combo is restored (persistence via `mv.hotkey.*`).
12. Try binding to a combo already in use by another app — confirm the slot shows the conflict warning and the old hotkey no longer fires.

### URL scheme (Stream Deck path)

> URL-scheme registration only works in the bundled `.app` — not in `swift run`.

13. With `NoNoiseMac.app` running: `open nonoisemac://toggle` in Terminal. Confirm AI toggles.
14. `open nonoisemac://bypass` — confirm bypass activates (orange banner if popover is open).
15. `open nonoisemac://preset/next` — confirm preset cycles.
16. `open nonoisemac://clarity/next` — confirm Broadcast Voice cycles.
17. `open nonoisemac://gain/up` — confirm gain increases.
18. **Stream Deck:** Add a "Open" button → URL → `nonoisemac://toggle`. Press the button on the Stream Deck. Confirm AI toggles.

### CLI action mode

19. (Requires the `.app` to be running and registered): `./NoNoiseMacCLI --action toggle` — confirm AI toggles.
20. `./NoNoiseMacCLI --action preset-next` — confirm preset cycles.
21. `./NoNoiseMacCLI --help` — confirm the Stream Deck URL reference and verb list are printed.

### Persistence

22. Set a non-default preset, toggle bypass, quit and relaunch. Confirm:
    - Preset restored correctly.
    - Bypass is NOT restored (it is session-only, not persisted).
    - `isAIEnabled` is restored to its pre-bypass value.

### Regression

23. With all features off (AI on, default preset, clarity off, no bypass), confirm the audio output is byte-for-byte equivalent to a build without this feature (the control layer only dispatches; it has no DSP path of its own).

---

## Self-Review (completed during authoring)

- **Entitlement impact:** Zero. Carbon `RegisterEventHotKey` works with the existing two keys.
  No third key added. `nonoisemac://` URL scheme is a `Info.plist` declaration, not an
  entitlement. `NSEvent` global monitors are explicitly NOT used.
- **Hotkey API choice documented:** Carbon vs NSEvent tradeoff explained in context section,
  in `HotkeyManager.swift` inline comment, and in `AGENTS.md`. No ambiguity left for future agents.
- **URL-scheme SwiftPM caveat documented:** Task 4 Step 3 note + smoke test calls it out.
  `swift run` will NOT register the scheme; only the bundled `.app` will.
- **A/B bypass persistence contract documented:** Bypass state is session-only. When bypass
  ends, `isAIEnabled` is restored to its saved preference, not persisted. Confirmed in smoke
  test step 22.
- **`mv.*` namespace preserved:** All new persistence keys use `mv.hotkey.*` (consistent with
  the existing `mv.preset`, `mv.suppressionStrength`, etc.).
- **No MetalVoice/Ghostkwebb in Sources/:** New files are in `Sources/App/` and use the
  `NoNoiseMac`/`ActionDispatcher`/`HotkeyManager`/`ControlAction` identifiers.
- **Render thread untouched:** `ActionDispatcher.dispatch` writes to `AudioModel`'s
  `@Published` properties on the main thread — the same pattern as the existing `outputGainValue`
  knob. No new lock or synchronisation primitive needed.
- **Placeholder scan:** No placeholders. All code shown is complete and copy-pasteable.
- **Type consistency:** `ControlAction`, `HotkeyBinding`, `HotkeyActionID`, `HotkeyManager`,
  `ActionDispatcher`, `KeyCaptureView`, `RebindSheet`, `HotkeySettingsView` used consistently
  across tasks. `HotkeyActionID` conforms to `Identifiable` in the UI task where needed.
