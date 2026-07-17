import Foundation
import Combine

/// No-op stand-in for the removed Sparkle updater. This fork is built from source and
/// updated via git, so in-app update checks are permanently unavailable. The type keeps
/// the original surface (`canCheckForUpdates` / `checkForUpdates()`) so the popover and
/// Settings UI compile unchanged; the "Check for Updates…" item stays disabled forever.
@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init() {}

    func checkForUpdates() {}
}
