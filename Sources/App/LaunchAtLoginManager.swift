import Combine
import Core
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState = .notRegistered
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool { state.isEnabled }

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            state = .enabled
        case .notRegistered:
            state = .notRegistered
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            state = .notFound
        @unknown default:
            state = .notFound
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch let error as NSError where enabled && error.code == Int(kSMErrorAlreadyRegistered) {
            // Registration is idempotent from the user's perspective.
            errorMessage = nil
        } catch {
            errorMessage = "NoNoise Mac could not update its login item."
        }

        refresh()
    }

    func openLoginItems() {
        guard #available(macOS 14.0, *) else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
