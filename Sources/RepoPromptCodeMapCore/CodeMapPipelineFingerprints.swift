import Foundation

/// P2 step 13: the Rust core is the codemap pipeline authority (vendored
/// grammar crates + `queries/*.scm`). This file is a frozen Swift mirror of
/// the per-language pipeline fingerprint (grammar revision, tree-sitter ABI
/// version, and SHA-256 of the exact query bytes the Rust engine compiles
/// in). It exists only to feed `CodeMapPipelineIdentity` so cache identity
/// rotates whenever the Rust pipeline changes.
///
/// Do not edit the generated block by hand-derived values: it is
/// machine-checked by `rust/crates/runtime/tests/codemap_query_contract.rs`
/// (`swift_pipeline_fingerprint_mirror_matches_rust_truth`), which prints the
/// exact replacement block on any drift.
package struct CodeMapPipelineFingerprint: Sendable {
    package let grammarRevision: String
    package let treeSitterABIVersion: UInt32
    package let querySHA256Hex: String

    package init(grammarRevision: String, treeSitterABIVersion: UInt32, querySHA256Hex: String) {
        self.grammarRevision = grammarRevision
        self.treeSitterABIVersion = treeSitterABIVersion
        self.querySHA256Hex = querySHA256Hex
    }
}

package enum CodeMapPipelineFingerprints {
    // GENERATED-BEGIN: rust codemap pipeline authority
    package static let table: [LanguageType: CodeMapPipelineFingerprint] = [
        .swift: CodeMapPipelineFingerprint(
            grammarRevision: "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5",
            treeSitterABIVersion: 14,
            querySHA256Hex: "415b7eadff7b381b31cecb33cbcb5258b3aaddebcdfb2bd2f5a8c677b1824c28"
        ),
        .js: CodeMapPipelineFingerprint(
            grammarRevision: "44c892e0be055ac465d5eeddae6d3e194424e7de",
            treeSitterABIVersion: 15,
            querySHA256Hex: "0187d8a19d0ae4525a0907591c49288c29852596f1f4e7068ab267eb3d26d35f"
        ),
        .c_sharp: CodeMapPipelineFingerprint(
            grammarRevision: "cac6d5fb595f5811a076336682d5d595ac1c9e85",
            treeSitterABIVersion: 15,
            querySHA256Hex: "c01dcbf83cc133e6d118f8851fe46fc604fd3638319430b266b6cb8c624b3a71"
        ),
        .python: CodeMapPipelineFingerprint(
            grammarRevision: "293fdc02038ee2bf0e2e206711b69c90ac0d413f",
            treeSitterABIVersion: 15,
            querySHA256Hex: "4a45744089083d508b17355772d3095dafff2ba9e17c1f29397dcde7f4253b0b"
        ),
        .c: CodeMapPipelineFingerprint(
            grammarRevision: "b780e47fc780ddc8da13afa35a3f4ed5c157823d",
            treeSitterABIVersion: 15,
            querySHA256Hex: "5eb3aa141cf370d47954d7115b32a91537d9feffa51b5d1dc1ddc49b3b094329"
        ),
        .rust: CodeMapPipelineFingerprint(
            grammarRevision: "77a3747266f4d621d0757825e6b11edcbf991ca5",
            treeSitterABIVersion: 15,
            querySHA256Hex: "2671b0b6373102606593a8c2dd99e82d32f10c3bae7752feadc98aba8eaf5cac"
        ),
        .cpp: CodeMapPipelineFingerprint(
            grammarRevision: "f41e1a044c8a84ea9fa8577fdd2eab92ec96de02",
            treeSitterABIVersion: 14,
            querySHA256Hex: "0b6ce29cb0e919e27b8b69bdb1d407f7c37a8066c3661fe830b9c5e42aeca87e"
        ),
        .go: CodeMapPipelineFingerprint(
            grammarRevision: "1547678a9da59885853f5f5cc8a99cc203fa2e2c",
            treeSitterABIVersion: 15,
            querySHA256Hex: "d0ae466320f269287449eb678c4676b9b05760f345ede10d879dbb76e70747c9"
        ),
        .java: CodeMapPipelineFingerprint(
            grammarRevision: "94703d5a6bed02b98e438d7cad1136c01a60ba2c",
            treeSitterABIVersion: 14,
            querySHA256Hex: "14bf7e26d0aed53ce8080feb067407083e356071967628338a1e264255f403b5"
        ),
        .ts: CodeMapPipelineFingerprint(
            grammarRevision: "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
            treeSitterABIVersion: 14,
            querySHA256Hex: "b1f801168d0c00af0e9029d419f12cbf7f82c461f0b9f5fdb1b76f8613f9a472"
        ),
        .tsx: CodeMapPipelineFingerprint(
            grammarRevision: "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
            treeSitterABIVersion: 14,
            querySHA256Hex: "b1f801168d0c00af0e9029d419f12cbf7f82c461f0b9f5fdb1b76f8613f9a472"
        ),
        .php: CodeMapPipelineFingerprint(
            grammarRevision: "5b5627faaa290d89eb3d01b9bf47c3bb9e797dea",
            treeSitterABIVersion: 15,
            querySHA256Hex: "8018027a61bbccdd77fe9d2f167cb50524361370c6b79b97a5d1be9021d2e726"
        ),
        .ruby: CodeMapPipelineFingerprint(
            grammarRevision: "71bd32fb7607035768799732addba884a37a6210",
            treeSitterABIVersion: 14,
            querySHA256Hex: "684567cfd7fdbb8ba4093c8ed0f51dd3ef6c2736db573c1b6ec7c2ee0e178b7e"
        ),
    ]
    // GENERATED-END: rust codemap pipeline authority
}
