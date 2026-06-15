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

        // Hand the dispatcher to the AppDelegate at LAUNCH (finding #3) — NOT in
        // ContentView.onAppear. A MenuBarExtra's content view isn't instantiated until the
        // popover first opens, so wiring the URL fallback in onAppear leaves AppDelegate's
        // application(_:open:) with a nil dispatcher until then: a bundled .app would drop
        // `open nonoisemac://toggle` fired before the popover was ever opened. The
        // @NSApplicationDelegateAdaptor's wrapped value is constructed before this init body
        // runs, so `appDelegate` is available here.
        appDelegate.dispatcher = dispatcher
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(audioModel: audioModel, dispatcher: dispatcher, hotkeyManager: hotkeyManager)
        } label: {
            Image(nsImage: NoNoiseLogoImage.menuBar(isActive: audioModel.isAIEnabled))
        }
        .menuBarExtraStyle(.window)
        // `nonoisemac://` opens are handled by AppDelegate.application(_:open:) (wired at launch
        // above). SwiftUI's `.onOpenURL` is a View modifier that does NOT apply to a `MenuBarExtra`
        // Scene, and a menu-bar app has no always-present content view to attach it to — the
        // popover content isn't instantiated until first open. Routing exclusively through the
        // AppDelegate keeps URL handling live from launch (pre-popover) AND avoids the
        // double-dispatch that two parallel handlers would cause (e.g. preset/next advancing twice).
    }
}

// @MainActor on the whole delegate: AppKit delivers these callbacks on the main thread, and it
// lets us touch the @MainActor `dispatcher` and call `dispatch(_:)` without a concurrency error.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wired by NoNoiseMacApp.init() at LAUNCH (finding #3), so the URL fallback below has a
    /// dispatcher before the popover is ever opened.
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
