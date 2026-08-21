import MCP
@testable import RepoPromptApp
import XCTest

/// P2 step 13: the legacy Swift `ApplyEditsEngine` (and its `DiffChunkGenerator`
/// / `DiffChunkApplier` / `UnifiedDiffRendering` ports) were deleted once the
/// production Rust seam (`RustApplyEditsComputer`) was verified as a hard-
/// assertion match on all 16 differential fixtures (see
/// `docs/architecture/rust-apply-edits-compact-v1.md`, "Step 12 batch
/// differential" / "Step 13 apply-edits verdict: GO").
///
/// This file used to also exercise `ApplyEditsEngine.default` directly
/// (rewrite/escaped-fallback/unmatched/batch-literal/batch-diff-success/
/// batch-diff-partial scenarios); that coverage now lives against the Rust
/// seam in `ApplyEditsRustFixtureExpectationTests`, so those cases were not
/// duplicated here.
///
/// One scenario has no Rust-seam equivalent and was intentionally dropped
/// rather than reconstructed: `testEmptyGeneratedChunksFailThroughApplyEditsInternalError`
/// injected an `EmptyDiffChunkGenerator` (a Swift-only test seam) to force
/// `ApplyEditsError.internalError` for `internalError`-classification
/// coverage. `rust-apply-edits-compact-v1.md`'s own step-13 verdict already
/// recorded this as a known, non-blocking coverage gap: no fixture in the
/// differential naturally reaches `RustApplyEditsComputer`'s `internalError`
/// branch (only reachable if the Rust core itself returns a malformed
/// subject count/shape), so there is no equivalent trigger to port.
///
/// What remains here is request-payload normalization coverage
/// (`ApplyEditsRequestBuilder`), which is unrelated to the compute engine
/// and was not part of the Rust cutover.
final class ApplyEditsRequestBuilderTests: XCTestCase {
    private let builder = ApplyEditsRequestBuilder()

    func testRequestBuilderAcceptsBatchPayloadShapes() throws {
        struct Case {
            let name: String
            let args: [String: Value]
            let expectedReplaceAll: Bool
        }

        let cases: [Case] = [
            Case(
                name: "edits array",
                args: [
                    "path": .string("file.swift"),
                    "edits": .array([
                        .object([
                            "search": .string("old"),
                            "replace": .string("new")
                        ])
                    ])
                ],
                expectedReplaceAll: false
            ),
            Case(
                name: "single edits object",
                args: [
                    "path": .string("file.swift"),
                    "edits": .object([
                        "search": .string("old"),
                        "with": .string("new"),
                        "all": .bool(true)
                    ])
                ],
                expectedReplaceAll: true
            ),
            Case(
                name: "JSON edits array string",
                args: [
                    "path": .string("file.swift"),
                    "edits": .string("[{\"search\":\"old\",\"replace\":\"new\"}]")
                ],
                expectedReplaceAll: false
            ),
            Case(
                name: "args tool wrapper",
                args: [
                    "args": .string("{\"apply_edits\":{\"path\":\"file.swift\",\"edits\":{\"search\":\"old\",\"content\":\"new\"}}}")
                ],
                expectedReplaceAll: false
            )
        ]

        for testCase in cases {
            let request = try builder.build(from: testCase.args)
            XCTAssertEqual(request.path, "file.swift", testCase.name)
            switch request.mode {
            case let .batch(edits):
                XCTAssertEqual(edits.count, 1, testCase.name)
                XCTAssertEqual(edits[0].search, "old", testCase.name)
                XCTAssertEqual(edits[0].replace, "new", testCase.name)
                XCTAssertEqual(edits[0].replaceAll, testCase.expectedReplaceAll, testCase.name)
            default:
                XCTFail("Expected batch mode for \(testCase.name)")
            }
        }
    }
}
