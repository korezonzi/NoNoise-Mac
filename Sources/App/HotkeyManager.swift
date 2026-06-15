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
