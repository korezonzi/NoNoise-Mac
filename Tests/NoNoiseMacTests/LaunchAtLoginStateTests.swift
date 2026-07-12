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
