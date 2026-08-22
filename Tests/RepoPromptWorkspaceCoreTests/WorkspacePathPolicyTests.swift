@testable import RepoPromptWorkspaceCore
import XCTest

final class WorkspacePathPolicyTests: XCTestCase {
    func testStandardizedPathsNormalizeAndPreserveContainmentBoundaries() {
        XCTAssertEqual(StandardizedPath.relative("/Sources/./Models/../App.swift/"), "Sources/App.swift")
        XCTAssertEqual(StandardizedPath.join(standardizedRoot: "/repo", standardizedRelativePath: "Sources/App.swift"), "/repo/Sources/App.swift")
        XCTAssertTrue(StandardizedPath.isDescendant("/repo/Sources/App.swift", of: "/repo"))
        XCTAssertFalse(StandardizedPath.isDescendant("/repository/App.swift", of: "/repo"))
        XCTAssertEqual(StandardizedPath.diagnosticEscaped("bad\0path\n"), "bad\\0path\\n")
    }

    func testAliasResolutionUsesDeterministicGeneratedAliasesForDuplicateNames() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/Clients/One/App")
        let second = makeRoot(name: "App", fullPath: "/Users/test/Clients/Two/App")
        let roots = [first, second]

        XCTAssertEqual(ClientPathFormatter.nonAbsoluteRootAlias(root: first, visibleRoots: roots), "One/App")
        XCTAssertEqual(ClientPathFormatter.nonAbsoluteRootAlias(root: second, visibleRoots: roots), "Two/App")

        XCTAssertEqual(
            WorkspaceAliasResolver.resolve(
                userPath: "Two/App/Sources/File.swift",
                roots: roots,
                options: RootAliasOptions(requireRemainder: true)
            ),
            .prefixed(root: second, alias: "Two/App", remainder: "Sources/File.swift")
        )
    }

    func testExactFileInputParsesLiteralExplicitAndAbsoluteForms() throws {
        XCTAssertEqual(try WorkspaceExactFileInput.parse("mimic/session.py"), .relative("mimic/session.py"))
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("One/App//Sources/./File.swift"),
            .explicitRoot(alias: "One/App", relativePath: "Sources/File.swift")
        )
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("~/Sources/../File.swift"),
            .absolute(StandardizedPath.absolute(("~/Sources/../File.swift" as NSString).expandingTildeInPath))
        )
        XCTAssertEqual(try WorkspaceExactFileInput.parse("App:Sources/File.swift"), .relative("App:Sources/File.swift"))
        XCTAssertEqual(try WorkspaceExactFileInput.parse(" Target.swift"), .relative(" Target.swift"))
        XCTAssertEqual(
            try WorkspaceExactFileInput.parse("~/Project//File.swift"),
            .explicitRoot(alias: "~/Project", relativePath: "File.swift")
        )
    }

    func testExactFileInputRejectsMalformedExplicitQualifier() {
        for input in ["App//", "App///File.swift", "App//Dir//File.swift", "../File.swift"] {
            XCTAssertThrowsError(try WorkspaceExactFileInput.parse(input), "Expected rejection for \(input)")
        }
    }

    func testExplicitWorkspaceFilePathUsesCanonicalGeneratedAlias() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/Clients/One/App")
        let second = makeRoot(name: "App", fullPath: "/Users/test/Clients/Two/App")

        XCTAssertEqual(
            ClientPathFormatter.explicitWorkspaceFilePath(
                root: second,
                relativePath: "Sources/File.swift",
                visibleRoots: [first, second]
            ),
            "root@\(second.id.uuidString.lowercased())//Sources/File.swift"
        )
    }

    func testExactRootAliasesRemainUniqueAcrossDisplayAliasCollisions() {
        let first = makeRoot(name: "Project", fullPath: "/Docs")
        let second = makeRoot(name: "Project", fullPath: "/tmp/Project")
        let canonicalNameCollision = makeRoot(name: "Docs", fullPath: "/else/Docs")
        let generatedAliasCollision = makeRoot(
            name: "root@\(first.id.uuidString.lowercased())",
            fullPath: "/natural/collision"
        )
        let roots = [first, second, canonicalNameCollision, generatedAliasCollision]
        let aliases = ClientPathFormatter.exactRootAliases(visibleRoots: roots)

        XCTAssertEqual(Set(aliases.values.map { $0.lowercased() }).count, roots.count)
        XCTAssertNotEqual(aliases[first.id]?.lowercased(), aliases[canonicalNameCollision.id]?.lowercased())
        XCTAssertTrue(
            ClientPathFormatter.explicitWorkspaceFilePath(
                root: first,
                relativePath: "shared.txt",
                visibleRoots: roots
            ).hasSuffix("//shared.txt")
        )
    }

    func testAmbiguousRootMessageUsesExplicitQualifier() {
        let root = makeRoot(name: "App", fullPath: "/Users/test/App")
        let message = PathResolutionIssueRenderer.message(
            for: .ambiguousRootMatch(input: "Sources/File.swift", candidateRoots: [root])
        )

        XCTAssertTrue(message.contains("<root-alias>//<relative-path>"))
    }

    func testCreatePreflightRejectsAmbiguousAndImplicitMultiRootPaths() {
        let first = makeRoot(name: "App", fullPath: "/Users/test/AppOne")
        let second = makeRoot(name: "App", fullPath: "/Users/test/AppTwo")

        XCTAssertThrowsError(
            try CreatePathPreflight.validate(
                userPath: "App/Sources/File.swift",
                visibleRoots: [first, second]
            )
        ) { error in
            guard case let CreatePathPreflight.Error.ambiguousAlias(alias, matchingRoots) = error else {
                return XCTFail("Expected ambiguousAlias, got \(error)")
            }
            XCTAssertEqual(alias, "App")
            XCTAssertEqual(Set(matchingRoots), Set([first, second]))
        }

        let distinct = makeRoot(name: "Docs", fullPath: "/Users/test/Docs")
        XCTAssertThrowsError(
            try CreatePathPreflight.validate(
                userPath: "Sources/File.swift",
                visibleRoots: [first, distinct]
            )
        ) { error in
            guard case let CreatePathPreflight.Error.missingAliasWithMultipleRoots(loadedRoots) = error else {
                return XCTFail("Expected missingAliasWithMultipleRoots, got \(error)")
            }
            XCTAssertEqual(loadedRoots, [first, distinct])
        }
    }

    func testMovePathResolverRejectsAmbiguousAndCrossRootAliases() throws {
        let source = makeRoot(name: "AppA", fullPath: "/Users/test/AppA")
        let other = makeRoot(name: "AppB", fullPath: "/Users/test/AppB")

        XCTAssertThrowsError(
            try MovePathResolver.resolveRelativePathInRoot(
                userPath: "AppB/Sources/File.swift",
                sourceRoot: source,
                visibleRoots: [source, other]
            )
        ) { error in
            guard case let MovePathResolver.Error.crossRootAlias(alias, resolvedRoot) = error else {
                return XCTFail("Expected crossRootAlias, got \(error)")
            }
            XCTAssertEqual(alias, "AppB")
            XCTAssertEqual(resolvedRoot, other)
        }

        let duplicateA = makeRoot(name: "App", fullPath: "/Users/test/AppOne")
        let duplicateB = makeRoot(name: "App", fullPath: "/Users/test/AppTwo")
        XCTAssertThrowsError(
            try MovePathResolver.resolveRelativePathInRoot(
                userPath: "App/Sources/File.swift",
                sourceRoot: duplicateA,
                visibleRoots: [duplicateA, duplicateB]
            )
        ) { error in
            guard case let MovePathResolver.Error.ambiguousAlias(alias, matchingRoots) = error else {
                return XCTFail("Expected ambiguousAlias, got \(error)")
            }
            XCTAssertEqual(alias, "App")
            XCTAssertEqual(Set(matchingRoots), Set([duplicateA, duplicateB]))
        }
    }

    // P4-1 contract freeze (docs/architecture/rust-inventory-scope-v1.md §6): CompactQueryV1
    // carries one per-root display prefix, computed once in Swift via
    // ClientPathFormatter.displayPath's branch selection, plus a distinct empty-relative-path
    // override value. Rust then does plain string concatenation per row (the same shape
    // WorkspaceSearchCatalogEntry.defaultDisplayPath uses today) and never re-derives branch
    // selection. This pins that decomposition against all three branches plus the
    // empty-relative-path case that every branch special-cases.
    func testInventoryQueryDisplayPrefixCompositionMatchesClientPathFormatterAcrossAllBranchesAndEmptyRelativePath() {
        let solo = makeRoot(name: "App", fullPath: "/Users/test/App")
        let uniqueA = makeRoot(name: "AppOne", fullPath: "/Users/test/One/App")
        let uniqueB = makeRoot(name: "AppTwo", fullPath: "/Users/test/Two/App")
        let ambiguousA = makeRoot(name: "App", fullPath: "/Users/test/ClientOne/App")
        let ambiguousB = makeRoot(name: "App", fullPath: "/Users/test/ClientTwo/App")

        let cases: [(label: String, root: WorkspaceRootRef, visibleRoots: [WorkspaceRootRef])] = [
            ("branch 1: single visible root, no prefix", solo, [solo]),
            ("branch 2: multiple roots, unique name, name/ prefix", uniqueA, [uniqueA, uniqueB]),
            ("branch 3: multiple roots, ambiguous name, standardizedFullPath/ prefix", ambiguousA, [ambiguousA, ambiguousB])
        ]

        for testCase in cases {
            let prefix = inventoryQueryDisplayPrefix(root: testCase.root, visibleRoots: testCase.visibleRoots)

            for relativePath in ["Sources/File.swift", "", "Nested/Dir/Leaf.swift"] {
                let composed = relativePath.isEmpty ? prefix.emptyRelativePathValue : prefix.value + relativePath
                let reference = ClientPathFormatter.displayPath(
                    root: testCase.root,
                    relativePath: relativePath,
                    visibleRoots: testCase.visibleRoots
                )
                XCTAssertEqual(
                    composed,
                    reference,
                    "\(testCase.label), relativePath=\"\(relativePath)\""
                )
            }
        }
    }

    /// Mirrors the frozen `CompactQueryV1` contract: Swift computes one display prefix per root
    /// (the non-empty-relative-path form) plus a distinct empty-relative-path override value,
    /// since every branch of `ClientPathFormatter.displayPath` special-cases the empty relative
    /// path rather than reducing to `prefix + ""`.
    private struct InventoryQueryDisplayPrefix {
        let value: String
        let emptyRelativePathValue: String
    }

    private func inventoryQueryDisplayPrefix(
        root: WorkspaceRootRef,
        visibleRoots: [WorkspaceRootRef]
    ) -> InventoryQueryDisplayPrefix {
        if visibleRoots.count <= 1 {
            return InventoryQueryDisplayPrefix(value: "", emptyRelativePathValue: root.name)
        }
        let canonicalMatches = visibleRoots.filter { $0.name.caseInsensitiveCompare(root.name) == .orderedSame }
        if canonicalMatches.count == 1 {
            return InventoryQueryDisplayPrefix(value: root.name + "/", emptyRelativePathValue: root.name)
        }
        return InventoryQueryDisplayPrefix(
            value: root.standardizedFullPath + "/",
            emptyRelativePathValue: root.standardizedFullPath
        )
    }

    private func makeRoot(id: UUID = UUID(), name: String, fullPath: String) -> WorkspaceRootRef {
        WorkspaceRootRef(id: id, name: name, fullPath: fullPath)
    }
}
