use agentry_runtime::{
    FolderSuffixRequest, LeafCancellation, PathClause, PathFilterRequest, PathSnapshot,
    RuntimeIdentity, SearchLeaf,
};

fn identity() -> RuntimeIdentity {
    RuntimeIdentity::new(1, "a".repeat(32), "b".repeat(64), "c".repeat(64)).unwrap()
}

fn cancellation() -> LeafCancellation {
    LeafCancellation::new(identity())
}

fn snapshot(full: &str, relative: &str, root: &str, display: &str) -> PathSnapshot {
    PathSnapshot {
        standardized_full_path: full.into(),
        standardized_relative_path: relative.into(),
        standardized_root_path: root.into(),
        client_display_path: display.into(),
    }
}

#[test]
fn path_empty_exact_file_and_root_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let snapshots = vec![snapshot("/A/File.swift", "File.swift", "/A", "File.swift")];
    let empty = leaf.filter_paths(&PathFilterRequest {
        snapshots: snapshots.clone(),
        clauses: vec![],
        case_insensitive: true,
        cancellation: cancellation(),
    });
    assert!(empty.matched_snapshot_indices.is_empty());
    assert_eq!(empty.visited_snapshot_count, 1);

    let exact = leaf.filter_paths(&PathFilterRequest {
        snapshots,
        clauses: vec![PathClause::ExactFile {
            abs_path: "/other".into(),
            rel_path: "File.swift".into(),
            restricted_root_path: Some("/A".into()),
        }],
        case_insensitive: true,
        cancellation: cancellation(),
    });
    assert_eq!(exact.matched_snapshot_indices, vec![0]);
}

#[test]
fn path_exact_folder_legacy_order_and_dedup_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let snapshots = vec![
        snapshot(
            "/A/Sources/App/File.swift",
            "Sources/App/File.swift",
            "/A",
            "App/File.swift",
        ),
        snapshot(
            "/A/Tests/Test.swift",
            "Tests/Test.swift",
            "/A",
            "Tests/Test.swift",
        ),
    ];
    let result = leaf.filter_paths(&PathFilterRequest {
        snapshots,
        clauses: vec![
            PathClause::ExactFolder {
                abs_lower: "/a/sources".into(),
                rel_lower: "sources".into(),
                restricted_root_path: Some("/A".into()),
            },
            PathClause::LegacyPrefix {
                candidate_lower: "tests".into(),
            },
            PathClause::LegacyPrefix {
                candidate_lower: "sources".into(),
            },
        ],
        case_insensitive: true,
        cancellation: cancellation(),
    });
    assert_eq!(result.matched_snapshot_indices, vec![0, 1]);
}

#[test]
fn path_glob_wildstar_slash_range_escape_and_casefold_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let snapshots = vec![
        snapshot(
            "/A/Sources/Deep/File1.SWIFT",
            "Sources/Deep/File1.SWIFT",
            "/A",
            "Deep/File1.SWIFT",
        ),
        snapshot(
            "/A/Sources/Filex.swift",
            "Sources/Filex.swift",
            "/A",
            "Sources/Filex.swift",
        ),
    ];
    let result = leaf.filter_paths(&PathFilterRequest {
        snapshots,
        clauses: vec![PathClause::Glob {
            pattern: "Sources/**/File[0-9].swift".into(),
            restricted_root_path: Some("/A".into()),
        }],
        case_insensitive: true,
        cancellation: cancellation(),
    });
    assert_eq!(result.matched_snapshot_indices, vec![0]);

    let zero_components = leaf.filter_paths(&PathFilterRequest {
        snapshots: vec![snapshot(
            "/A/Sources/File1.swift",
            "Sources/File1.swift",
            "/A",
            "Sources/File1.swift",
        )],
        clauses: vec![PathClause::Glob {
            pattern: "Sources/**/File?.swift".into(),
            restricted_root_path: Some("/A".into()),
        }],
        case_insensitive: false,
        cancellation: cancellation(),
    });
    assert_eq!(zero_components.matched_snapshot_indices, vec![0]);
}

#[test]
fn path_folder_suffix_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let result = leaf.folder_suffix_indices(&FolderSuffixRequest {
        fragment: "/App/./Models/".into(),
        relative_paths: vec![
            "Sources/App/Models".into(),
            "App/Views".into(),
            "App/Models".into(),
        ],
        case_insensitive: true,
        cancellation: cancellation(),
    });
    assert_eq!(result, vec![0, 2]);
}
