import Foundation
import Combine   // ObservableObject / @Published
import SwiftUI   // Binding (aiToggleBinding for the popover master toggle — finding #2)
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

    /// Mirrors `state.isBypassed` for the SwiftUI bypass banner (Task 6) and gates the popover
    /// master toggle (finding #2): the UI toggle is disabled while bypassed so a user cannot
    /// re-enable AI processing against an active bypass.
    @Published public private(set) var isBypassed: Bool = false

    public init(model: AudioModel) {
        self.model = model
        // Seed desired-AI from the model's current (persisted) value.
        self.state = ControlState(desiredAI: model.isAIEnabled,
                                  preset: model.selectedPreset,
                                  clarity: model.clarityLevel,
                                  gain: model.outputGainValue)
    }

    /// The popover master toggle binds to this instead of `$audioModel.isAIEnabled` (finding #2),
    /// so flipping AI in the UI goes through the SAME desired-vs-effective path as `.toggleAI`.
    /// `get` reflects the model's live (effective) value; `set` dispatches `.toggleAI` ONLY when
    /// the requested value differs, so the desired/bypass bookkeeping stays correct. The toggle is
    /// disabled while bypassed (see `ContentView`), so this setter is never invoked mid-bypass.
    ///
    /// SwiftUI evaluates a `Binding`'s closures on the main thread, so reading the `@MainActor`
    /// `model`/`isAIEnabled` and calling `dispatch(_:)` here is main-actor-safe. Under this
    /// package's Swift 5.9 default concurrency checking this compiles without `@Sendable`
    /// annotation; if a future Swift-6 mode flags the captured-`self` closures, mark them
    /// `@MainActor` (do NOT move the toggle back to a direct `$audioModel.isAIEnabled` binding,
    /// which reopens the bypass back door).
    public var aiToggleBinding: Binding<Bool> {
        Binding(
            get: { [weak self] in self?.model?.isAIEnabled ?? false },
            set: { [weak self] newValue in
                guard let self, let model = self.model else { return }
                if model.isAIEnabled != newValue { self.dispatch(.toggleAI) }
            }
        )
    }

    // MARK: - Dispatch

    /// Run one action through the pure reducer and apply ONLY the emitted mutations to AudioModel.
    /// NEVER blanket-writes every field: a blanket write of `outputGainValue` re-trips
    /// `onKnobChanged()` (demoting the active preset to `.custom`), and writing `outputGainValue`
    /// AFTER a preset change overrides the preset's own gain (`applyPreset`). Applying only the
    /// reducer's mutations keeps preset/gain/clarity untouched unless the action changed them.
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

        let (next, mutations) = ControlReducer.reduce(state, action)
        state = next

        // Apply ONLY the fields the action actually changed. Order: preset first (it applies its
        // own gain/atten via AudioModel.applyPreset), so a same-action .setGain would already have
        // been suppressed by the reducer — there is never both .setPreset and .setGain in one list.
        for mutation in mutations {
            switch mutation {
            case .setPreset(let preset):    model.selectedPreset = preset
            case .setClarity(let clarity):  model.clarityLevel = clarity
            case .setGain(let gain):        model.outputGainValue = gain
            case .setAIEffective(let on):   model.isAIEnabled = on
            }
        }

        isBypassed = state.isBypassed
    }
}
