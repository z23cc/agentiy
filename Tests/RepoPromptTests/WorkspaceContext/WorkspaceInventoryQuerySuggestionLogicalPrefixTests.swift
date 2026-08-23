import Foundation
@testable import RepoPromptApp
import XCTest

/// P4-7a phase a1 (design doc §5.1, done-when 2): extends
/// `WorkspacePathPolicyTests.testInventoryQueryDisplayPrefixCompositionMatchesClientPathFormatterAcrossAllBranchesAndEmptyRelativePath`
/// (`Tests/RepoPromptWorkspaceCoreTests`) to the `.Suggestion` haystack's `logicalPath` component.
///
/// That test lives in the `RepoPromptWorkspaceCore` package, which has no visibility into
/// `WorkspaceRootBindingProjection` (an app-target type) -- so this is the sibling extension in the
/// app-target test tree, over the same underlying algorithm rather than a duplicate reimplementation:
/// `WorkspaceRootBindingProjection.projectedLogicalDisplayPath(forPhysicalPath:)` composes via
/// `ClientPathFormatter.displayPath(root: logicalRoot, relativePath:, visibleRoots: visibleLogicalRootRefs)`
/// -- the identical three-branch algorithm the physical-prefix test already pins, just over the
/// *logical* root/visible-roots pair instead of the physical one. What this test proves that the
/// existing one cannot: that a **per-physical-root** prefix pair (computed once, the same shape
/// `CompactQueryV1`'s a3 wire will carry) reproduces `projectedLogicalDisplayPath`'s per-*entry*
/// composition for every entry's relative path under that root -- i.e. that the per-root
/// abstraction the design's `logical_prefix: Option<QueryPrefix>` field relies on is actually valid,
/// not just that the branch-selection formula matches in isolation.
final class WorkspaceInventoryQuerySuggestionLogicalPrefixTests: XCTestCase {
    private func assertLogicalPrefixReproducesProjectedLogicalDisplayPath(
        logicalRoot: WorkspaceRootRef,
        physicalRoot: WorkspaceRootRef,
        visibleLogicalRoots: [WorkspaceRootRef],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let binding = AgentSessionWorktreeBinding(
            id: "binding-\(label)",
            repositoryID: "repo-\(label)",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-\(label)",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        let projection = WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)],
            visibleLogicalRoots: visibleLogicalRoots
        )
        let prefix = ClientPathFormatter.displayPrefix(root: logicalRoot, visibleRoots: visibleLogicalRoots)

        // The corpus of relative paths every entry under this physical root could have, including
        // the empty-relative-path (root-level entry) special case every branch handles distinctly.
        for relativePath in ["", "Sources/File.swift", "Nested/Dir/Leaf.swift"] {
            let physicalPath = relativePath.isEmpty
                ? physicalRoot.fullPath
                : physicalRoot.fullPath + "/" + relativePath
            let expected = try XCTUnwrap(
                projection.projectedLogicalDisplayPath(forPhysicalPath: physicalPath),
                "\(label), relativePath=\"\(relativePath)\"",
                file: file,
                line: line
            )
            let composed = relativePath.isEmpty
                ? prefix.emptyRelativePathValue
                : prefix.nonEmptyRelativePrefix + relativePath
            XCTAssertEqual(
                composed,
                expected,
                "\(label), relativePath=\"\(relativePath)\"",
                file: file,
                line: line
            )
        }
    }

    func testLogicalPrefixReproducesProjectedLogicalDisplayPathAcrossAllBranchesAndEmptyRelativePath() throws {
        let physicalRoot = WorkspaceRootRef(id: UUID(), name: "PhysWorktree", fullPath: "/tmp/worktrees/app-agent")

        // Branch 1: solo visible logical root -- no prefix, empty-relative override is the root name.
        let solo = WorkspaceRootRef(id: UUID(), name: "App", fullPath: "/Users/test/App")
        try assertLogicalPrefixReproducesProjectedLogicalDisplayPath(
            logicalRoot: solo,
            physicalRoot: physicalRoot,
            visibleLogicalRoots: [solo],
            label: "branch 1: single visible logical root, no prefix"
        )

        // Branch 2: multiple logical roots, unique name -- "name/" prefix.
        let uniqueA = WorkspaceRootRef(id: UUID(), name: "AppOne", fullPath: "/Users/test/One/App")
        let uniqueB = WorkspaceRootRef(id: UUID(), name: "AppTwo", fullPath: "/Users/test/Two/App")
        try assertLogicalPrefixReproducesProjectedLogicalDisplayPath(
            logicalRoot: uniqueA,
            physicalRoot: physicalRoot,
            visibleLogicalRoots: [uniqueA, uniqueB],
            label: "branch 2: multiple logical roots, unique name, name/ prefix"
        )

        // Branch 3: multiple logical roots, ambiguous name -- "standardizedFullPath/" prefix.
        let ambiguousA = WorkspaceRootRef(id: UUID(), name: "App", fullPath: "/Users/test/ClientOne/App")
        let ambiguousB = WorkspaceRootRef(id: UUID(), name: "App", fullPath: "/Users/test/ClientTwo/App")
        try assertLogicalPrefixReproducesProjectedLogicalDisplayPath(
            logicalRoot: ambiguousA,
            physicalRoot: physicalRoot,
            visibleLogicalRoots: [ambiguousA, ambiguousB],
            label: "branch 3: multiple logical roots, ambiguous name, standardizedFullPath/ prefix"
        )
    }
}
