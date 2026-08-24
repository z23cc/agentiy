use std::fs;
use std::path::{Path, PathBuf};

use agentry_runtime::codemap::{
    CodeMapArtifact, CodeMapLanguage, CodeMapSourceKind, CodeMapSubjectRequestV1, SubjectOutcome,
    build_subject,
};

struct Fixture {
    language: CodeMapLanguage,
    relative: &'static str,
    golden: &'static str,
}

const FIXTURES: [Fixture; 13] = [
    Fixture {
        language: CodeMapLanguage::C,
        relative: "c/smoke.c",
        golden: "c_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Python,
        relative: "py/smoke.py",
        golden: "py_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::JavaScript,
        relative: "js/smoke.js",
        golden: "js_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Swift,
        relative: "swift/smoke.swift",
        golden: "swift_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::TypeScript,
        relative: "ts/smoke.ts",
        golden: "ts_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Tsx,
        relative: "tsx/component.tsx",
        golden: "tsx_component.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::CSharp,
        relative: "cs/smoke.cs",
        golden: "cs_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Rust,
        relative: "rs/smoke.rs",
        golden: "rs_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Cpp,
        relative: "cpp/edge_methods.cpp",
        golden: "cpp_edge_methods.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Go,
        relative: "go/smoke.go",
        golden: "go_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Java,
        relative: "java/smoke.java",
        golden: "java_smoke.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Php,
        relative: "php/edge_namespaces.php",
        golden: "php_edge_namespaces.codemap.txt",
    },
    Fixture {
        language: CodeMapLanguage::Ruby,
        relative: "rb/smoke.rb",
        golden: "rb_smoke.codemap.txt",
    },
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn artifact(fixture: &Fixture) -> CodeMapArtifact {
    let source = fs::read(
        repo_root()
            .join("Tests/RepoPromptCodeMapCoreTests/Fixtures")
            .join(fixture.relative),
    )
    .unwrap();
    let request = CodeMapSubjectRequestV1 {
        language_id: fixture.language.id(),
        source_kind: CodeMapSourceKind::Decoded,
        source_utf8: source,
    };
    match build_subject(&request).unwrap() {
        SubjectOutcome::Ready(value) => value,
        outcome => panic!("unexpected outcome: {outcome:?}"),
    }
}

fn render(fixture: &Fixture, artifact: &CodeMapArtifact) -> String {
    let mut value = format!("File: <ROOT>/{}\nImports:", fixture.relative);
    for import in &artifact.imports {
        value.push_str(&format!("\n  - {import}"));
    }
    value.push_str(&artifact.api_description());
    value
}

#[test]
fn codemap_golden_all_thirteen_languages() {
    let golden_root = repo_root().join("Tests/RepoPromptCodeMapCoreTests/Goldens");
    for fixture in &FIXTURES {
        let expected = fs::read_to_string(golden_root.join(fixture.golden)).unwrap();
        let actual = render(fixture, &artifact(fixture));
        assert_eq!(
            actual.trim_end(),
            expected.trim_end(),
            "{}",
            fixture.relative
        );
    }
}

// -------------------------------------------------------------------------------------------
// TD-3 R7 (design `docs/designs/textdecode-policy-v2-2026-08-22.md` §6.2/§10): a UTF-8-BOM
// source file run through the full codemap artifact pipeline, not just decode. Before this
// migration, no BOM byte ever reached `rust/crates/runtime/src/codemap/` -- ladder 1's strict-
// UTF-8 fast path silently stripped it before codemap ever saw the string. `CodeMapSourceKind::
// Raw` (TD-3 §6.1) is the first time a leading U+FEFF scalar reaches tree-sitter here. This
// proves symbol extraction is unaffected -- same functions/classes/line numbers as the non-BOM
// artifact -- not merely that decode is byte-correct (which `textdecode`'s own TD-2 fixtures
// already cover).
// -------------------------------------------------------------------------------------------

#[test]
fn codemap_utf8_bom_prefixed_source_produces_the_same_symbols_as_the_non_bom_source_r7() {
    let fixture = &FIXTURES[3]; // Swift smoke fixture -- real-language source, not synthetic.
    let plain_source = fs::read(
        repo_root()
            .join("Tests/RepoPromptCodeMapCoreTests/Fixtures")
            .join(fixture.relative),
    )
    .unwrap();
    let plain = match build_subject(&CodeMapSubjectRequestV1 {
        language_id: fixture.language.id(),
        source_kind: CodeMapSourceKind::Decoded,
        source_utf8: plain_source.clone(),
    })
    .unwrap()
    {
        SubjectOutcome::Ready(value) => value,
        outcome => panic!("unexpected non-BOM outcome: {outcome:?}"),
    };

    let mut bom_prefixed = vec![0xEFu8, 0xBB, 0xBF];
    bom_prefixed.extend_from_slice(&plain_source);
    let bom = match build_subject(&CodeMapSubjectRequestV1 {
        language_id: fixture.language.id(),
        source_kind: CodeMapSourceKind::Raw,
        source_utf8: bom_prefixed,
    })
    .unwrap()
    {
        SubjectOutcome::Ready(value) => value,
        outcome => panic!("unexpected BOM outcome: {outcome:?}"),
    };

    assert!(
        !plain.functions.is_empty(),
        "fixture must exercise at least one function"
    );
    // Characterized, not assumed: D-5 (design §9) mandates BOM preservation, so the raw text of
    // whatever token captures line 1 keeps its leading U+FEFF -- here, the first `import`. This
    // is the *only* place the BOM surfaces in the artifact; it is not a position shift or a
    // corrupted/missing symbol (every other assertion below is byte-for-byte identical), so it
    // is not the R7 failure mode this fixture exists to catch, but it is a real, deterministic
    // divergence that must be asserted explicitly rather than assumed away.
    assert_eq!(plain.imports.len(), bom.imports.len());
    assert_eq!(bom.imports[0], format!("\u{FEFF}{}", plain.imports[0]));
    assert_eq!(&plain.imports[1..], &bom.imports[1..]);
    assert_eq!(plain.exports, bom.exports);
    assert_eq!(plain.classes, bom.classes);
    assert_eq!(plain.interfaces, bom.interfaces);
    assert_eq!(
        plain.functions, bom.functions,
        "BOM must not shift function line numbers/signatures"
    );
    assert_eq!(plain.enums, bom.enums);
    assert_eq!(plain.global_vars, bom.global_vars);
    assert_eq!(plain.aliases, bom.aliases);
    assert_eq!(plain.literal_unions, bom.literal_unions);
    assert_eq!(plain.macros, bom.macros);
    assert_eq!(plain.referenced_types, bom.referenced_types);
}

#[test]
fn codemap_capture_all_thirteen_languages() {
    for fixture in &FIXTURES {
        let source = fs::read_to_string(
            repo_root()
                .join("Tests/RepoPromptCodeMapCoreTests/Fixtures")
                .join(fixture.relative),
        )
        .unwrap();
        let captures = agentry_runtime::codemap::parse_captures(fixture.language, &source).unwrap();
        assert!(!captures.is_empty(), "{}", fixture.relative);
        assert!(
            captures
                .iter()
                .all(|capture| capture.start_byte <= capture.end_byte
                    && capture.end_byte <= source.len()),
            "{}",
            fixture.relative
        );
    }
}

#[test]
fn codemap_extraction_preserves_swift_nested_symbol_shape() {
    let fixture = FIXTURES
        .iter()
        .find(|value| value.language == CodeMapLanguage::Swift)
        .unwrap();
    let artifact = artifact(fixture);
    let class = artifact
        .classes
        .iter()
        .find(|value| value.name == "FriendlyGreeter")
        .unwrap();
    assert_eq!(class.properties[0].name, "let prefix: String");
    assert_eq!(class.methods[0].parameters[0].local_name, "name");
    assert_eq!(class.methods[0].return_type.as_deref(), Some("String"));
    assert_eq!(artifact.interfaces[0].name, "Greeter");
}

#[test]
fn codemap_extraction_preserves_typescript_aliases_and_members() {
    let fixture = FIXTURES
        .iter()
        .find(|value| value.language == CodeMapLanguage::TypeScript)
        .unwrap();
    let artifact = artifact(fixture);
    assert_eq!(
        artifact
            .aliases
            .iter()
            .map(|value| value.name.as_str())
            .collect::<Vec<_>>(),
        ["User"]
    );
    assert_eq!(artifact.interfaces[0].properties[0].name, "user: User");
    assert_eq!(
        artifact.classes[0].methods[1].return_type.as_deref(),
        Some("string")
    );
}
