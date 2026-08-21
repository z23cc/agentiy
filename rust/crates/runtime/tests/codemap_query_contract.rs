use std::fs;
use std::path::{Path, PathBuf};

use agentry_runtime::codemap::{CodeMapLanguage, descriptor};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn swift_query(file: &str) -> String {
    let source = fs::read_to_string(
        repo_root()
            .join("Sources/RepoPromptCodeMapCore/Queries")
            .join(file),
    )
    .unwrap();
    let start = source.find("#\"\"\"").unwrap() + 4;
    let end = source[start..].find("\"\"\"#").unwrap() + start;
    source[start..end].to_owned()
}

#[test]
fn codemap_query_bytes_match_swift_authority() {
    let entries = [
        (CodeMapLanguage::Swift, "SwiftQueries.swift"),
        (CodeMapLanguage::JavaScript, "JavaScriptQueries.swift"),
        (CodeMapLanguage::CSharp, "cSharpQueries.swift"),
        (CodeMapLanguage::Python, "PythonQueries.swift"),
        (CodeMapLanguage::C, "cQueries.swift"),
        (CodeMapLanguage::Rust, "RustQueries.swift"),
        (CodeMapLanguage::Cpp, "cppQueries.swift"),
        (CodeMapLanguage::Go, "GoQueries.swift"),
        (CodeMapLanguage::Java, "JavaQueries.swift"),
        (CodeMapLanguage::TypeScript, "typeScript.swift"),
        (CodeMapLanguage::Tsx, "typeScript.swift"),
        (CodeMapLanguage::Php, "phpQueries.swift"),
        (CodeMapLanguage::Ruby, "RubyQueries.swift"),
    ];
    for (language, file) in entries {
        // Compare query content with EOF-newline normalization: the Swift
        // authority literals end with trailing blank lines that the repo
        // whitespace gate forbids in checked-in .scm files. Content parity
        // (everything before the final newlines) remains byte-exact.
        assert_eq!(
            descriptor(language).query.trim_end_matches('\n').as_bytes(),
            swift_query(file).trim_end_matches('\n').as_bytes(),
            "{language}"
        );
    }
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
