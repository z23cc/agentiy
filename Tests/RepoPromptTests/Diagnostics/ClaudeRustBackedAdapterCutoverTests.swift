import Foundation
import XCTest

/// P6-8/P6-9 cutover guard: every interactive Claude-compatible variant must construct the one
/// Rust-backed adapter in every build. No variant-specific Swift controller or runtime rollback
/// flag may survive the authority transfer.
final class ClaudeRustBackedAdapterCutoverTests: XCTestCase {
    func testEveryInteractiveClaudeCompatibleVariantUsesTheSingleRustAuthority() throws {
        let root = try RepoRoot.url()
        let coordinatorURL = root.appendingPathComponent(
            "Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift"
        )
        let coordinator = try String(contentsOf: coordinatorURL, encoding: .utf8)
        let factory = try XCTUnwrap(
            sourceSlice(
                in: coordinator,
                from: "private static func makeDefaultController(",
                through: "@discardableResult\n    private func updateProviderSessionIDIfNeeded"
            )
        )

        XCTAssertEqual(factory.components(separatedBy: "return ClaudeRustBackedNativeSessionAdapter(").count - 1, 1)
        XCTAssertFalse(factory.contains("if launchSettings.runtimeVariant"))
        XCTAssertFalse(factory.contains("ClaudeCompatibleNativeSessionAdapter("))
        XCTAssertFalse(factory.contains("ClaudeNativeProcessSessionController("))
        XCTAssertFalse(factory.contains("#if DEBUG"))
    }

    func testDebugSelectionFlagAndReleaseExclusionAreRemoved() throws {
        let root = try RepoRoot.url()
        let adapterURL = root.appendingPathComponent(
            "Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeRustBackedNativeSessionAdapter.swift"
        )
        let selectionURL = root.appendingPathComponent(
            "Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeRustBackedNativeSessionAdapterSelection.swift"
        )
        let coordinatorURL = root.appendingPathComponent(
            "Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift"
        )
        let productionSources = try [adapterURL, coordinatorURL].map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertFalse(FileManager.default.fileExists(atPath: selectionURL.path))
        XCTAssertFalse(productionSources.contains("ClaudeRustBackedNativeSessionAdapterSelection"))
        XCTAssertFalse(productionSources.contains("AGENTRY_CLAUDE_RUST_BACKED_ADAPTER"))
        XCTAssertFalse(try String(contentsOf: adapterURL, encoding: .utf8).contains("#if DEBUG"))
    }

    private func sourceSlice(in source: String, from startMarker: String, through endMarker: String) -> String? {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start ..< source.endIndex)?.lowerBound
        else {
            return nil
        }
        return String(source[start ..< end])
    }
}
