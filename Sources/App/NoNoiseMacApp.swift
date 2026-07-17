import SwiftUI
import AppKit
import Combine
import Core

// NOTE (this fork): the original upstream app used SwiftUI's `MenuBarExtra`. On macOS 26 the
// status-item scene is managed by FrontBoard/ControlCenter, and on this machine the system
// delivered a terminate action to that scene at every launch (NSSceneStatusItem
// scene:handleActions: → NSApplication.terminate), killing the app ~3 s after start even with
// a clean "NSStatusItem VisibleCC" preference. The status item is therefore managed manually
// via NSStatusItem in the AppDelegate, which does not go through the scene system at all.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model = AudioModel()
        audioModel = model
        dispatcher = ActionDispatcher(model: model)
        hotkeyManager = HotkeyManager(dispatcher: dispatcher)   // registers Carbon hotkeys NOW
        updaterController = UpdaterController()
        launchAtLoginManager = LaunchAtLoginManager()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.behavior = []   // NOT .removalAllowed — Cmd-drag removal would strand a menu-bar-only app
        if let button = statusItem.button {
            button.image = NoNoiseLogoImage.menuBar(isActive: model.isAIEnabled)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        // Keep the icon's active tint in sync with the AI toggle (was the MenuBarExtra label binding).
        iconCancellable = model.$isAIEnabled
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

    /// URL handler for `nonoisemac://` actions — live from launch, same as upstream.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = ControlAction.from(url: url) else { continue }
            dispatcher?.dispatch(action)
        }
    }
}
