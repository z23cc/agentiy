import Foundation
import XCTest

/// P6-7 (`docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-7, `docs/architecture/
/// rust-agent-claude-v1.md` §1.1's release-symbol-absence discipline, mirrored for the Swift-side
/// selection flag): the Rust-backed `NativeAgentRuntimeControlling` adapter is not authoritative
/// and must never be reachable from a release build. `ClaudeRustBackedNativeSessionAdapter.swift`
/// and `ClaudeRustBackedNativeSessionAdapterSelection.swift` are entirely `#if DEBUG`-gated, and
/// `ClaudeAgentModeCoordinator.makeDefaultController`'s Rust-arm branch is gated the same way --
/// this test strips every `#if DEBUG` block from all three (the same source-projection technique
/// `WorktreeStartupBenchmarkReleaseAbsenceTests` uses) and asserts the resulting release-only
/// projection contains no reference to the adapter type, its selection flag, or the flag's
/// environment-variable name.
final class ClaudeRustBackedAdapterReleaseAbsenceTests: XCTestCase {
    func testReleaseProjectionOmitsTheRustBackedAdapterAndItsSelectionFlag() throws {
        let root = try RepoRoot.url()
        let files = [
            "Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeRustBackedNativeSessionAdapter.swift",
            "Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeRustBackedNativeSessionAdapterSelection.swift",
            "Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift"
        ]
        let projection = try files.map { path in
            try releaseProjection(String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }.joined(separator: "\n")
        for forbidden in [
            "ClaudeRustBackedNativeSessionAdapter",
            "ClaudeRustBackedNativeSessionAdapterSelection",
            "AGENTRY_CLAUDE_RUST_BACKED_ADAPTER"
        ] {
            XCTAssertFalse(projection.contains(forbidden), "Release source projection leaked \(forbidden)")
        }
    }

    /// Same stripping algorithm as `WorktreeStartupBenchmarkReleaseAbsenceTests.releaseProjection`
    /// (duplicated rather than shared -- both are small, single-file-scoped test helpers, and
    /// neither file is a natural shared-utility owner).
    private func releaseProjection(_ source: String) -> String {
        struct Frame { let parentIncluded: Bool
            let debugCondition: Bool
            var inElse: Bool
        }
        var frames: [Frame] = []
        var included = true
        var output: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let directive = line.trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#if ") {
                let isDebug = directive == "#if DEBUG"
                frames.append(Frame(parentIncluded: included, debugCondition: isDebug, inElse: false))
                included = included && !isDebug
            } else if directive == "#else", var frame = frames.popLast() {
                frame.inElse.toggle()
                frames.append(frame)
                included = frame.parentIncluded && (frame.debugCondition || !frame.debugCondition)
            } else if directive == "#endif", let frame = frames.popLast() {
                included = frame.parentIncluded
            } else if included {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }
}
