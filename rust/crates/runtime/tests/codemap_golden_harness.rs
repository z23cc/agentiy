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
