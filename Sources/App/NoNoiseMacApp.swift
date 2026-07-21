import SwiftUI
import AppKit
import Combine
import Core

// NOTE (this fork): the original upstream app used SwiftUI's `MenuBarExtra`. On macOS 26 the
// menu bar is managed per-bundle-id by FrontBoard/ControlCenter, and this machine's management
// DB held a poisoned "hidden" registration for the upstream id `com.ivalsaraj.NoNoiseMac`.
// That single root cause produced two different symptoms:
//   1. MenuBarExtra: FrontBoard delivered a terminate action to the status-item scene at every
//      launch (NSSceneStatusItem scene:handleActions: → NSApplication.terminate) — app died ~3 s in.
//   2. Raw NSStatusItem: the item's window was created but never adopted by the layout — parked
//      off-screen, permanently occluded, on BOTH displays, immune to isVisible pins, pref-key
//      resets and ControlCenter restarts.
// Proof: the identical binary under a fresh bundle id lays out and draws normally (probe test).
// Fix: this fork's CFBundleIdentifier is `com.korezonzi.NoNoiseMac` (see also the one-shot
// defaults migration below). The status item stays manually managed via NSStatusItem in the
// AppDelegate — it works fine under the new id and gives us the right-click menu for free.
// The empty Settings scene below exists only because a SwiftUI `App` must declare a scene.
@main
struct NoNoiseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// @MainActor on the whole delegate: AppKit delivers these callbacks on the main thread, and it
// lets us touch the @MainActor model/dispatcher objects without a concurrency error.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // Launch-time singletons (same init order rule as upstream:
    // AudioModel → ActionDispatcher(model:) → HotkeyManager(dispatcher:)).
    private(set) var audioModel: AudioModel!
    private(set) var dispatcher: ActionDispatcher!
    private(set) var hotkeyManager: HotkeyManager!
    private(set) var updaterController: UpdaterController!
    private(set) var launchAtLoginManager: LaunchAtLoginManager!

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconCancellable: AnyCancellable?

    /// One-shot migration of user settings from the upstream bundle id's defaults domain.
    /// This fork changed CFBundleIdentifier (com.ivalsaraj.NoNoiseMac → com.korezonzi.NoNoiseMac)
    /// because macOS 26's menu-bar item management held a poisoned "hidden" registration for the
    /// old id — the status item's window was created but stayed permanently occluded/parked
    /// off-screen, on every launch, regardless of isVisible/pref-key/ControlCenter resets. The
    /// same binary under a fresh id lays out and draws normally (verified with a probe bundle).
    /// A new id means a new defaults domain, so copy the user's mv.* settings across once.
    private static func migrateDefaultsFromUpstreamID() {
        let d = UserDefaults.standard
        let markerKey = "mv.migratedFromIvalsarajID"
        guard !d.bool(forKey: markerKey) else { return }
        if let old = d.persistentDomain(forName: "com.ivalsaraj.NoNoiseMac") {
            for (key, value) in old where key.hasPrefix("mv.") && d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
        }
        d.set(true, forKey: markerKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.migrateDefaultsFromUpstreamID()   // BEFORE AudioModel() — its init reads UserDefaults

        let model = AudioModel()
        audioModel = model
        dispatcher = ActionDispatcher(model: model)
        hotkeyManager = HotkeyManager(dispatcher: dispatcher)   // registers Carbon hotkeys NOW
        updaterController = UpdaterController()
        launchAtLoginManager = LaunchAtLoginManager()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.behavior = []   // NOT .removalAllowed — Cmd-drag removal would strand a menu-bar-only app
        // Force-visible: NSStatusItem autosaves visibility under "NSStatusItem Visible* Item-0",
        // and a stale `= 0` (recorded back in the MenuBarExtra days, or by a menu-bar manager)
        // silently restores the item as HIDDEN on every launch — app runs, no icon anywhere.
        // A menu-bar-only app must never start invisible, so pin it true after creation.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NoNoiseLogoImage.menuBar(isActive: model.isAIEnabled)
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            // Left click opens the popover (existing behavior); right click pops up the
            // context menu (Turn All On/Off, Open Controls, Quit) — see handleStatusItemClick.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // Keep the icon's active tint in sync with mic NC OR either receive-side cleanup backend
        // (was AI-only; extended so the icon reflects "is anything running" at a glance — was the
        // MenuBarExtra label binding).
        iconCancellable = Publishers.CombineLatest3(
                model.$isAIEnabled,
                model.$speakerCleanupEnabled,
                model.$incomingCleanupEnabled
            )
            .map { aiEnabled, speakerEnabled, incomingEnabled in
                aiEnabled || speakerEnabled || incomingEnabled
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.statusItem.button?.image = NoNoiseLogoImage.menuBar(isActive: active)
            }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView(
            audioModel: model,
            dispatcher: dispatcher,
            hotkeyManager: hotkeyManager,
            updaterController: updaterController,
            launchAtLoginManager: launchAtLoginManager
        ))
    }

    /// Single `button.action` target for both click kinds (registered via `sendAction(on:)`
    /// above). AppKit doesn't route right vs. left click to different selectors on its own, so
    /// we inspect `NSApp.currentEvent` — the event that triggered this action — to branch.
    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePopover(sender)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Right-click context menu: one-click all-on/off, open the popover, quit. Built fresh on
    /// every right click so "Turn All On/Off" always reflects the CURRENT state.
    ///
    /// The menu is assigned to `statusItem.menu` only for the duration of this single click,
    /// then cleared — a persistently-set `statusItem.menu` would make AppKit route LEFT clicks
    /// through it too (bypassing `button.action`/`handleStatusItemClick` entirely), which would
    /// silently break the left-click-opens-popover behavior.
    private func showStatusMenu() {
        guard let button = statusItem.button else { return }

        let anyOn = audioModel.isAIEnabled || audioModel.speakerCleanupEnabled || audioModel.incomingCleanupEnabled

        let menu = NSMenu()

        let toggleAllItem = NSMenuItem(
            title: anyOn ? "Turn All Off" : "Turn All On",
            action: #selector(toggleAllFromMenu),
            keyEquivalent: ""
        )
        toggleAllItem.target = self
        menu.addItem(toggleAllItem)

        menu.addItem(.separator())

        let openControlsItem = NSMenuItem(
            title: "Open Controls",
            action: #selector(openControlsFromMenu),
            keyEquivalent: ""
        )
        openControlsItem.target = self
        menu.addItem(openControlsItem)

        let quitItem = NSMenuItem(
            title: "Quit NoNoise Mac",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleAllFromMenu() {
        dispatcher?.dispatch(.toggleAll)
    }

    /// "Open Controls" always SHOWS the popover (never toggles it closed) — distinct from the
    /// left-click action, which does toggle.
    @objc private func openControlsFromMenu() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down live HAL pipelines and cancel any deferred engine start before the process
        // dies — without this, an in-flight deferred speaker start could fire during teardown
        // (audit finding), and a SIGTERM mid-IO leaves driver-side state for coreaudiod to clean.
        audioModel?.shutdownCleanupEngines()
    }

    /// URL handler for `nonoisemac://` actions — live from launch, same as upstream.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = ControlAction.from(url: url) else { continue }
            dispatcher?.dispatch(action)
        }
    }
}
