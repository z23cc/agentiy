use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

use agentry_runtime::codemap::{CodeMapLanguage, descriptor};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// P2 step 13: the legacy Swift codemap extraction stack (and its
/// `Queries/*.swift` authority files) was deleted. The Rust engine is now the
/// sole pipeline authority: the vendored `queries/*.scm` bytes, the vendored
/// grammar crates' ABI versions, and the frozen grammar revisions below are
/// the truth. The Swift side keeps only a frozen fingerprint mirror
/// (`CodeMapPipelineFingerprints.swift`) used for cache/pipeline identity;
/// this test forces that mirror to stay byte-identical to the Rust truth so
/// any `.scm`/grammar change rotates Swift-side cache identity.
const MIRROR_RELATIVE_PATH: &str =
    "Sources/RepoPromptCodeMapCore/CodeMapPipelineFingerprints.swift";
const BEGIN_MARKER: &str = "    // GENERATED-BEGIN: rust codemap pipeline authority";
const END_MARKER: &str = "    // GENERATED-END: rust codemap pipeline authority";

const LANGUAGES: [(CodeMapLanguage, &str); 13] = [
    (CodeMapLanguage::Swift, "swift"),
    (CodeMapLanguage::JavaScript, "js"),
    (CodeMapLanguage::CSharp, "c_sharp"),
    (CodeMapLanguage::Python, "python"),
    (CodeMapLanguage::C, "c"),
    (CodeMapLanguage::Rust, "rust"),
    (CodeMapLanguage::Cpp, "cpp"),
    (CodeMapLanguage::Go, "go"),
    (CodeMapLanguage::Java, "java"),
    (CodeMapLanguage::TypeScript, "ts"),
    (CodeMapLanguage::Tsx, "tsx"),
    (CodeMapLanguage::Php, "php"),
    (CodeMapLanguage::Ruby, "ruby"),
];

fn hex(bytes: impl AsRef<[u8]>) -> String {
    bytes
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn expected_generated_block() -> String {
    let mut out = String::new();
    out.push_str(
        "    package static let table: [LanguageType: CodeMapPipelineFingerprint] = [\n",
    );
    for (language, swift_key) in LANGUAGES {
        let langdesc = descriptor(language);
        let abi = langdesc.tree_sitter_language().abi_version();
        let sha = hex(Sha256::digest(langdesc.query.as_bytes()));
        out.push_str(&format!(
            "        .{swift_key}: CodeMapPipelineFingerprint(\n            grammarRevision: \"{}\",\n            treeSitterABIVersion: {abi},\n            querySHA256Hex: \"{sha}\"\n        ),\n",
            langdesc.grammar_revision
        ));
    }
    out.push_str("    ]\n");
    out
}

#[test]
fn swift_pipeline_fingerprint_mirror_matches_rust_truth() {
    let path = repo_root().join(MIRROR_RELATIVE_PATH);
    let source = fs::read_to_string(&path).unwrap_or_default();
    let expected = expected_generated_block();
    let actual = source.find(BEGIN_MARKER).and_then(|start| {
        let body_start = start + BEGIN_MARKER.len() + 1;
        source[body_start..]
            .find(END_MARKER)
            .map(|end| source[body_start..body_start + end].to_owned())
    });
    assert_eq!(
        actual.as_deref(),
        Some(expected.as_str()),
        "Swift pipeline fingerprint mirror is out of sync with the Rust authority.\n\
         Replace the block between the GENERATED markers in {MIRROR_RELATIVE_PATH} with exactly:\n\n{expected}"
    );
}

#[test]
fn codemap_language_ids_and_grammar_revisions_are_frozen() {
    let revisions = [
        "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5",
        "44c892e0be055ac465d5eeddae6d3e194424e7de",
        "cac6d5fb595f5811a076336682d5d595ac1c9e85",
        "293fdc02038ee2bf0e2e206711b69c90ac0d413f",
        "b780e47fc780ddc8da13afa35a3f4ed5c157823d",
        "77a3747266f4d621d0757825e6b11edcbf991ca5",
        "f41e1a044c8a84ea9fa8577fdd2eab92ec96de02",
        "1547678a9da59885853f5f5cc8a99cc203fa2e2c",
        "94703d5a6bed02b98e438d7cad1136c01a60ba2c",
        "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
        "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
        "5b5627faaa290d89eb3d01b9bf47c3bb9e797dea",
        "71bd32fb7607035768799732addba884a37a6210",
    ];
    for (index, language) in CodeMapLanguage::ALL.into_iter().enumerate() {
        assert_eq!(language.id(), (index + 1) as u16);
        assert_eq!(descriptor(language).grammar_revision, revisions[index]);
    }
}
