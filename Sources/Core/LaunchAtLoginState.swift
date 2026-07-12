public enum LaunchAtLoginState: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound

    public var isEnabled: Bool {
        self == .enabled
    }

    public var needsSystemSettings: Bool {
        self == .requiresApproval || self == .notFound
    }
}
