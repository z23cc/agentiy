import Foundation
@testable import RepoPromptApp
import XCTest

/// E-P6-1(c) differential (`docs/designs/p6-claude-vertical-2026-08-23.md` section 8,
/// `docs/architecture/rust-agent-claude-v1.md` section 8): asserts the real
/// `MCPIntegrationHelper.isRepoPromptToolName(_:)` -- the host policy predicate frozen by the
/// P6-1 contract and ported into Rust translation -- agrees with a curated, hand-verified case
/// table over the full 27-entry alias table
/// plus adversarial prefixed/normalized/`functions.`-prefixed forms.
///
/// This is the **Swift arm** of the differential. The **Rust arm**
/// (`rust/spikes/agent-claude-derisking-spike/src/tool_owned.rs`'s `rust_port_matches_curated_fixture`
/// test) asserts the ported Rust predicate against the identical fixture file. Both green is the
/// pass criterion (c) evidence recorded in `rust/benchmarks/results/v1/p6-2-claude-derisking-v1.md`.
final class HostOwnedToolNamePredicateDifferentialTests: XCTestCase {
    private struct FixtureCase: Decodable {
        let input: String
        let expected: Bool
        let note: String
    }

    private struct Fixture: Decodable {
        let schemaVersion: Int
        let cases: [FixtureCase]
    }

    /// `rust/spikes/agent-claude-derisking-spike/fixtures/host-owned-tool-name-cases-v1.json` --
    /// five directories up from this file (drop the filename, then `ClaudeCompatible` ->
    /// `AgentMode` -> `RepoPromptTests` -> `Tests` -> repo root).
    private func fixtureURL() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // drop filename -> .../ClaudeCompatible
            .deletingLastPathComponent() // ClaudeCompatible -> .../AgentMode
            .deletingLastPathComponent() // AgentMode -> .../RepoPromptTests
            .deletingLastPathComponent() // RepoPromptTests -> .../Tests
            .deletingLastPathComponent() // Tests -> repo root
        let fixture = repoRoot
            .appendingPathComponent("rust/spikes/agent-claude-derisking-spike/fixtures/host-owned-tool-name-cases-v1.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("fixture not found at \(fixture.path) -- repo layout drift?")
        }
        return fixture
    }

    private func loadFixture() throws -> Fixture {
        let data = try Data(contentsOf: fixtureURL())
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testRealPredicateMatchesCuratedFixture() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.cases.isEmpty, "fixture must be non-empty")

        var mismatches: [String] = []
        for testCase in fixture.cases {
            let actual = MCPIntegrationHelper.isRepoPromptToolName(testCase.input)
            if actual != testCase.expected {
                mismatches.append(
                    "input=\(testCase.input.debugDescription) note=\(testCase.note.debugDescription) "
                        + "expected=\(testCase.expected) actual=\(actual)"
                )
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "E-P6-1(c) mismatch(es) against curated fixture:\n" + mismatches.joined(separator: "\n")
        )
    }

    func testFixtureCoversFullAliasTable() throws {
        let fixture = try loadFixture()
        let inputs = Set(fixture.cases.map(\.input))
        for name in MCPIntegrationHelper.repoPromptToolNames {
            XCTAssertTrue(inputs.contains(name), "fixture is missing exact-canonical coverage for \(name)")
        }
    }
}
