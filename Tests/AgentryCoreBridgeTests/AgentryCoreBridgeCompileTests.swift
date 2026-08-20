import XCTest
@testable import AgentryCoreBridge

final class AgentryCoreBridgeCompileTests: XCTestCase {
    func testBridgeModuleCompiles() {
        XCTAssertEqual(CoreConfiguration().dataLaneCapacity, 1_024)
    }
}
