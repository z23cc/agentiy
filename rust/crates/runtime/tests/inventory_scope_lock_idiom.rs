//! P4-3a done-when: "every `.lock()` site in the inventory scope uses
//! `.unwrap_or_else(|poisoned| poisoned.into_inner())` and none uses `.lock().unwrap()`,
//! enforced by a grep-based CI check or clippy lint over `rust/crates/runtime/src`"
//! (`docs/architecture/rust-inventory-scope-v1.md` §5.2.1, design §11 P4-3a).
//!
//! **Chosen enforcement shape (flagged, per the advisor consult during this step):** the crate
//! census at authoring time is 40 `.lock()` sites -- 37 using the closure spelling
//! `.unwrap_or_else(|poisoned| poisoned.into_inner())`, 2 using the equivalent function-reference
//! spelling `.unwrap_or_else(std::sync::PoisonError::into_inner)` (`search/cache.rs:49,:71`), and
//! 1 deliberate typed-error exception (`codemap/engine.rs:115`). A blanket "closure idiom
//! everywhere under `src/`" assertion would red-line those three pre-existing, legal,
//! already-reviewed sites. This checker therefore asserts two things instead, matching the
//! contract's own two-part sentence:
//! 1. **Crate-wide** (all of `rust/crates/runtime/src`): zero `.lock().unwrap()` sites (the
//!    "preserved verbatim" invariant the contract doc's `§2` census already states holds).
//! 2. **`inventory_scope/` specifically**: every `.lock()` call site uses the closure spelling
//!    exactly -- this module introduces no third idiom and no reliance on the pre-existing
//!    function-reference/typed-error exceptions.
//!
//! Matching is done on whitespace-normalized, line-comment-stripped file content (not raw lines)
//! so a `.lock()` call formatted across multiple lines (e.g. a `rustfmt`-wrapped method-chain) is
//! still detected correctly. The forbidden needle is built by concatenation rather than written
//! as a contiguous literal, so this checker's own source is not itself a false positive.

use std::fs;
use std::path::{Path, PathBuf};

const CLOSURE_IDIOM_NORMALIZED: &str = ".unwrap_or_else(|poisoned|poisoned.into_inner())";

fn bare_lock_unwrap_needle() -> String {
    let lock_call = [".", "l", "o", "c", "k", "(", ")"].concat();
    let bare_unwrap = [".", "u", "n", "w", "r", "a", "p", "(", ")"].concat();
    format!("{lock_call}{bare_unwrap}")
}

fn lock_call_needle() -> String {
    [".", "l", "o", "c", "k", "(", ")"].concat()
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

/// Strips `//...` line comments, then removes all whitespace, so a method chain split across
/// lines by `rustfmt` is seen as one contiguous token stream.
fn normalize(contents: &str) -> String {
    let mut normalized = String::with_capacity(contents.len());
    for line in contents.lines() {
        let code_part = line.split("//").next().unwrap_or("");
        normalized.extend(code_part.chars().filter(|c| !c.is_whitespace()));
    }
    normalized
}

fn runtime_src_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
}

#[test]
fn zero_bare_lock_unwrap_sites_anywhere_in_the_crate() {
    let mut files = Vec::new();
    rust_files(&runtime_src_root(), &mut files);
    assert!(
        !files.is_empty(),
        "expected to find runtime crate source files"
    );

    let needle = bare_lock_unwrap_needle();
    let mut violations = Vec::new();
    for file in &files {
        let contents = fs::read_to_string(file).expect("read source file");
        if normalize(&contents).contains(&needle) {
            violations.push(file.display().to_string());
        }
    }
    assert!(
        violations.is_empty(),
        "bare `.lock().unwrap()` found (forbidden crate-wide per §5.2.1):\n{}",
        violations.join("\n")
    );
}

#[test]
fn every_lock_site_in_inventory_scope_uses_the_closure_poison_recovery_idiom() {
    let scope_root = runtime_src_root().join("inventory_scope");
    let mut files = Vec::new();
    rust_files(&scope_root, &mut files);
    assert!(
        !files.is_empty(),
        "expected inventory_scope module files to exist"
    );

    let lock_call = lock_call_needle();
    let mut total_lock_sites = 0usize;
    let mut violations = Vec::new();
    for file in &files {
        let contents = fs::read_to_string(file).expect("read source file");
        let normalized = normalize(&contents);
        let mut search_from = 0usize;
        while let Some(relative_index) = normalized[search_from..].find(&lock_call) {
            total_lock_sites += 1;
            let match_start = search_from + relative_index;
            let after = &normalized[match_start + lock_call.len()..];
            if !after.starts_with(CLOSURE_IDIOM_NORMALIZED) {
                violations.push(format!(
                    "{}: `.lock()` not immediately followed by the closure poison-recovery idiom",
                    file.display()
                ));
            }
            search_from = match_start + lock_call.len();
        }
    }
    assert!(
        total_lock_sites > 0,
        "expected at least one `.lock()` site in inventory_scope -- the check would be vacuous otherwise"
    );
    assert!(
        violations.is_empty(),
        "inventory_scope `.lock()` site(s) not using `.unwrap_or_else(|poisoned| poisoned.into_inner())`:\n{}",
        violations.join("\n")
    );
}
