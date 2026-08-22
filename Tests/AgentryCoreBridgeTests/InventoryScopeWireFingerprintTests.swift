import XCTest
@testable import AgentryCoreBridge

/// Charter §15.3 item 6 / contract doc §3: `inventory-scope-v1` ships a Rust codec AND a
/// hand-written Swift mirror (`Sources/AgentryCoreBridge/CoreInventoryScope.swift`'s
/// `CoreInventoryScopeWire`), fingerprint-locked the way P2's codemap wire is locked. Rust is the
/// canonical schema source (`agentry_runtime::inventory_scope::wire::fingerprint`); this test
/// hardcodes the identical SHA-256 hex digest computed on the Rust side
/// (`inventory_scope::wire::tests::swift_mirror_fingerprint_matches_this_module`) so a shape
/// change on either side that isn't mirrored on the other fails exactly one of these two tests
/// red -- never both silently agreeing on a drifted shape.
final class InventoryScopeWireFingerprintTests: XCTestCase {
    func testSwiftMirrorFingerprintMatchesRustTruth() {
        XCTAssertEqual(
            CoreInventoryScopeWire.fingerprint(),
            "55c1365669c255965599349d27b470523428a85db4bf8709647b082fff0a63a9",
            """
            The Swift mirror's inventory-scope-v1 wire fingerprint no longer matches Rust's \
            (agentry_runtime::inventory_scope::wire::fingerprint). Re-derive both sides' \
            descriptor strings after confirming the shape change is intentional -- see \
            CoreInventoryScopeWire.fingerprint()'s doc comment.
            """
        )
    }
}
