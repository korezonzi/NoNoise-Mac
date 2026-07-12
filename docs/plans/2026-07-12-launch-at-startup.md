# Launch at Startup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a General Settings toggle that registers NoNoise Mac to launch automatically when the user logs in.

**Architecture:** Use macOS 13+ `SMAppService.mainApp` as the system-owned source of truth. Add a small app-layer manager that maps Service Management status into UI state, performs register/unregister operations, refreshes when Settings opens, and reports approval/errors without storing a duplicate preference in `UserDefaults`. The menu-bar app remains a single bundled executable; no helper, LaunchAgent plist, entitlement, or audio-model change is needed.

**Tech Stack:** Swift 5.9, SwiftUI, `ServiceManagement.SMAppService`, Swift Package Manager, XCTest.

**GitHub Issue:** #17 — https://github.com/ivalsaraj/NoNoise-Mac/issues/17

**Assumptions:** The setting is off by default on clean and existing installs unless macOS already reports the app as enabled. The user can change this default later without changing the architecture.

---

### Task 1: Add a headless launch-at-login state model

**Files:**
- Create: `/Users/valsaraj/Documents/projects/NoNoise-Mac/Sources/Core/LaunchAtLoginState.swift`
- Create: `/Users/valsaraj/Documents/projects/NoNoise-Mac/Tests/NoNoiseMacTests/LaunchAtLoginStateTests.swift`

**Step 1: Write the failing tests**

Cover the user-visible state rules without constructing `AudioModel` or calling the macOS Service Management daemon:

```swift
import XCTest
@testable import Core

final class LaunchAtLoginStateTests: XCTestCase {
    func testOnlyEnabledStateTurnsToggleOn() {
        XCTAssertTrue(LaunchAtLoginState.enabled.isEnabled)
        XCTAssertFalse(LaunchAtLoginState.notRegistered.isEnabled)
        XCTAssertFalse(LaunchAtLoginState.requiresApproval.isEnabled)
        XCTAssertFalse(LaunchAtLoginState.notFound.isEnabled)
    }

    func testApprovalAndNotFoundStatesRequestSystemSettingsGuidance() {
        XCTAssertTrue(LaunchAtLoginState.requiresApproval.needsSystemSettings)
        XCTAssertTrue(LaunchAtLoginState.notFound.needsSystemSettings)
        XCTAssertFalse(LaunchAtLoginState.enabled.needsSystemSettings)
        XCTAssertFalse(LaunchAtLoginState.notRegistered.needsSystemSettings)
    }
}
```

Run: `swift test --filter LaunchAtLoginStateTests`

Expected: FAIL because `LaunchAtLoginState` does not exist yet.

**Step 2: Implement the minimal state type**

Define an `Equatable` public enum with cases matching the four `SMAppService.Status` values: `.enabled`, `.notRegistered`, `.requiresApproval`, and `.notFound`. Add `public` computed properties `isEnabled` and `needsSystemSettings`; only `.enabled` returns true for `isEnabled`, while `.requiresApproval` and `.notFound` return true for `needsSystemSettings`. The access modifiers on these members are required because the App target consumes this Core type across the module boundary.

Do not import `ServiceManagement` into `Core`; keeping this value type Foundation-free preserves the existing headless test boundary.

**Step 3: Run the focused tests**

Run: `swift test --filter LaunchAtLoginStateTests`

Expected: PASS.

**Step 4: Commit the testable state contract**

```bash
git add Sources/Core/LaunchAtLoginState.swift Tests/NoNoiseMacTests/LaunchAtLoginStateTests.swift
git commit -m "test(core): define launch-at-login state contract"
```

### Task 2: Add the macOS Service Management adapter

**Files:**
- Create: `/Users/valsaraj/Documents/projects/NoNoise-Mac/Sources/App/LaunchAtLoginManager.swift`
- Modify: `/Users/valsaraj/Documents/projects/NoNoise-Mac/Package.swift`

**Step 1: Implement the manager around `SMAppService.mainApp`**

Create an `@MainActor final class LaunchAtLoginManager: ObservableObject` with:

- `@Published private(set) var state: LaunchAtLoginState = .notRegistered`.
- `private(set) var errorMessage: String?` for recoverable UI feedback.
- `var isEnabled: Bool { state.isEnabled }`.
- `init()` calling `refresh()`.
- `refresh()` reading `SMAppService.mainApp.status` and mapping all four statuses explicitly:
  - `.enabled` → `.enabled`;
  - `.notRegistered` → `.notRegistered`;
  - `.requiresApproval` → `.requiresApproval`;
  - `.notFound` → `.notFound`.
- `setEnabled(_ enabled: Bool)` that clears the previous error, calls `SMAppService.mainApp.register()` when enabling, calls `unregister()` when disabling, then calls `refresh()`.
- A recovery method that calls `SMAppService.openSystemSettingsLoginItems()` for the Settings button.

Treat `kSMErrorAlreadyRegistered` / an equivalent already-registered result as success by refreshing the system status. For other thrown errors, keep the previous effective state, set a concise `errorMessage`, and refresh so the UI cannot claim the item is enabled when macOS rejected the operation. Do not write a `mv.*` preference; Service Management owns persistence and reflects manual changes made in System Settings.

**Step 2: Link the system framework explicitly**

Add `.linkedFramework("ServiceManagement")` to the `NoNoiseMac` executable target’s `linkerSettings` in `Package.swift`. Keep the framework out of `Core` and do not add any entitlement.

**Step 3: Build the app target**

Run: `swift build`

Expected: PASS with `ServiceManagement` imported only by the app target.

**Step 4: Commit the adapter**

```bash
git add Sources/App/LaunchAtLoginManager.swift Package.swift
git commit -m "feat(app): manage launch at login with SMAppService"
```

### Task 3: Own the manager for the app lifetime and refresh it when Settings opens

**Files:**
- Modify: `/Users/valsaraj/Documents/projects/NoNoise-Mac/Sources/App/NoNoiseMacApp.swift`
- Modify: `/Users/valsaraj/Documents/projects/NoNoise-Mac/Sources/App/ContentView.swift`
- Modify: `/Users/valsaraj/Documents/projects/NoNoise-Mac/Sources/App/SettingsView.swift`

**Step 1: Add one app-lifetime `@StateObject`**

Instantiate `LaunchAtLoginManager` in `NoNoiseMacApp.init()` alongside `AudioModel`, `ActionDispatcher`, `HotkeyManager`, and `UpdaterController`. Retain it in `@StateObject` so there is one system-state owner, not a new manager each time the reused Settings panel is created.

**Step 2: Thread the manager through the existing Settings opening path**

Pass the observed manager into `ContentView`, extend `WindowManager.openSettings(...)` to accept it, and pass it into `SettingsView`. Add the matching `@ObservedObject` manager properties to `SettingsView` and `GeneralSettingsView`, forwarding the same instance into the existing `GeneralSettingsView` initializer. This is initializer/property plumbing only; the visible card is added in Task 4. Immediately before making the existing panel key and ordering it front, call `launchAtLoginManager.refresh()` so changes made externally in System Settings are reflected when the panel reopens.

Do not alter the Settings window’s existing meter-observation lifecycle or create a second window manager.

**Step 3: Build the app target**

Run: `swift build`

Expected: PASS with a single manager instance wired from `NoNoiseMacApp` to `SettingsView`.

**Step 4: Commit the lifecycle wiring**

```bash
git add Sources/App/NoNoiseMacApp.swift Sources/App/ContentView.swift Sources/App/SettingsView.swift
git commit -m "feat(app): retain launch-at-login state at app scope"
```

### Task 4: Add the General Settings card and user feedback

**Files:**
- Modify: `/Users/valsaraj/Documents/projects/NoNoise-Mac/Sources/App/SettingsView.swift`

**Step 1: Add a Launch at Startup card**

Using the manager properties added in Task 3, place a new app-level card immediately after `brandedHeader` and before the audio controls. Use a SwiftUI `Toggle` backed by a `Binding<Bool>` whose getter reads `launchAtLoginManager.isEnabled` and whose setter calls `setEnabled(_:)`; never bind directly to a writable `@Published` flag because the system registration can fail.

Use copy equivalent to:

```swift
Toggle(isOn: Binding(
    get: { launchAtLoginManager.isEnabled },
    set: { launchAtLoginManager.setEnabled($0) }
)) {
    VStack(alignment: .leading, spacing: 2) {
        Text("Launch at Startup").font(.subheadline)
        Text("Start NoNoise Mac automatically when you log in to your Mac.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
.toggleStyle(.switch)
```

Below the toggle, show status-specific guidance:

- `.requiresApproval`: explain that macOS requires approval in System Settings → General → Login Items, with an `Open Login Items` button.
- `.notFound`: explain that the feature requires a bundled app and offer the same button.
- `.failed` is not a state case; display `errorMessage` below the card when present, with an `Open Login Items` recovery button if the manager reports one.
- `.enabled` / `.notRegistered`: no extra message.

Keep the card clear that this launches the menu-bar app; it does not automatically enable or disable noise cancellation. Do not add the setting to Voice Profiles, `AudioModel`, or the audio Settings reset list.

**Step 2: Build and run headless tests**

Run:

```bash
swift test --filter LaunchAtLoginStateTests
swift build
```

Expected: both PASS. The Service Management call itself is intentionally excluded from headless tests because it depends on the installed, bundled application and the user’s Login Items authorization state.

**Step 3: Commit the Settings UI**

```bash
git add Sources/App/SettingsView.swift
git commit -m "feat(settings): add launch at startup toggle"
```

### Task 5: Update user and agent documentation

**Files:**
- Modify: `/Users/valsaraj/Documents/projects/NoNoise-Mac/README.md`
- Modify: `/Users/valsaraj/Documents/projects/NoNoise-Mac/AGENTS.md`
- Modify: `/Users/valsaraj/Documents/projects/NoNoise-Mac/docs/knowledge/timeline1.md`

**Step 1: Document the user-facing setting**

Add a concise README bullet and Settings guidance: open Settings → General → Launch at Startup; if macOS requests approval, enable NoNoise Mac under System Settings → General → Login Items. State that the setting is off by default and that the app must be installed/bundled for the system login item to work.

**Step 2: Document the implementation invariant**

Update the App architecture map in `AGENTS.md` to mention `LaunchAtLoginManager` and record that launch-at-login uses `SMAppService.mainApp` as the source of truth, not `UserDefaults`, LaunchAgents, or a new entitlement.

**Step 3: Append the timeline entry**

Add a dated entry under `2026-07-12` describing the new Settings toggle, the `SMAppService.mainApp` decision, the approval/error UI, and the bundled-app manual verification requirement.

**Step 4: Review documentation references**

Run:

```bash
rg -n -i "launch at startup|launch at login|SMAppService|Login Items" README.md AGENTS.md docs Sources Tests
```

Expected: all user-facing and implementation references use the same terminology and no stale LaunchAgent instructions exist.

**Step 5: Commit documentation**

```bash
git add README.md AGENTS.md docs/knowledge/timeline1.md
git commit -m "docs: document launch-at-startup behavior"
```

### Task 6: Verify the bundled-app integration

**Files:**
- No additional source files.

**Step 1: Run the full automated checks**

Run:

```bash
swift test
swift build
swift build -c release --arch arm64
```

Expected: all tests pass and both debug/release builds succeed.

**Step 2: Build the signed bundle**

Run: `./bundle.sh`

Expected: `NoNoiseMac.app` is created and `codesign --verify --deep --strict NoNoiseMac.app` passes.

**Step 3: Verify the Settings state machine in the bundled app**

1. Launch `NoNoiseMac.app`, open Settings → General, and confirm the new toggle is off on a clean install.
2. Turn it on and confirm the state settles to enabled, or that the UI gives the System Settings approval path.
3. If approval is required, click `Open Login Items`, enable NoNoise Mac, return to the app, reopen Settings, and confirm the toggle reflects the system state.
4. Turn it off and confirm the toggle returns to off after reopening Settings.
5. Log out and back in, or restart the Mac, and confirm the menu-bar app launches without opening a foreground window.
6. Run the app from `swift run` only as a negative check: the UI should explain that the bundled app is required rather than silently claiming registration succeeded.

**Step 4: Verify the existing audio behavior is unchanged**

With the app launched at login, confirm the existing menu-bar flow, microphone routing, AI default, hotkeys, and Settings reset behavior remain unchanged. No audio code or `SettingsResetPolicy` key list should be involved in this feature.

**Step 5: Final diff and status check**

Run:

```bash
git diff main...HEAD --stat
git status --short
```

Expected: only the feature commits are present; unrelated pre-existing files such as `.claude/` remain untouched.

---

## API reference

- [Apple: `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) — macOS 13+ Service Management API.
- [Apple: `SMAppService.mainApp`](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp) — configures the main app to launch at login.
- [Apple: `SMAppService.register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register()) — registration behavior and approval handling.

## Scope boundaries

- Do not create a `~/Library/LaunchAgents` plist.
- Do not add a login helper executable; the app itself is the login item.
- Do not add a UserDefaults key or migrate existing `mv.*` settings.
- Do not add entitlements or change the CoreAudio/CoreML pipeline.
- Do not make startup launch enable AI, auto-route devices, or alter any persisted audio setting.
