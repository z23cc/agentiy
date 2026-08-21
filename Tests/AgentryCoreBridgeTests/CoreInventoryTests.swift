@testable import AgentryCoreBridge
import Foundation
import XCTest

/// Focused unit coverage for the P3-2 inventory wire's UUID <-> word conversion, independent of
/// the cross-language round trip in `InventoryRustSwiftDifferentialTests`: pins the exact
/// hi/lo byte split so a hypothetical bug that is self-consistent on the Swift side (encode and
/// decode agreeing with each other but not with Rust's `uuid_to_words`/`uuid_from_words`) cannot
/// hide behind a full round trip.
final class CoreInventoryTests: XCTestCase {
    func testUUIDWordsMatchDocumentedBigEndianByteSplit() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let (hi, lo) = coreInventoryUUIDWords(id)
        XCTAssertEqual(hi, 0x0011_2233_4455_6677)
        XCTAssertEqual(lo, 0x8899_AABB_CCDD_EEFF)
        XCTAssertEqual(coreInventoryUUID(fromHi: hi, lo: lo), id)
    }

    func testUUIDWordsRoundTripForBoundaryValues() {
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            UUID(uuidString: "80000000-0000-0000-0000-000000000001")!,
        ]
        for id in ids {
            let (hi, lo) = coreInventoryUUIDWords(id)
            XCTAssertEqual(coreInventoryUUID(fromHi: hi, lo: lo), id, "round trip for \(id.uuidString)")
        }
    }
}
