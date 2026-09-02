import XCTest
@testable import Core

final class MicDeviceTests: XCTestCase {
    func testIdentifiableIDEqualsUID() {
        let device = MicDevice(uid: "uid-123", name: "USB Mic")
        XCTAssertEqual(device.id, device.uid)
        XCTAssertEqual(device.id, "uid-123")
    }

    func testEqualityByFields() {
        let a = MicDevice(uid: "uid-1", name: "Built-in Microphone")
        let b = MicDevice(uid: "uid-1", name: "Built-in Microphone")
        let differentUID = MicDevice(uid: "uid-2", name: "Built-in Microphone")
        let differentName = MicDevice(uid: "uid-1", name: "External Mic")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, differentUID)
        XCTAssertNotEqual(a, differentName)
    }
}
