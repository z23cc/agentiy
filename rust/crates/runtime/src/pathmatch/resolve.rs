//! P3-3 slice-2a: the workspace path-match resolution LADDER
//! (`PathMatcher.locate`'s ~301-648 body plus every helper it calls, driven over one immutable
//! snapshot exactly like `PathMatchWorker.locateMany`'s serial `for userPath in userPaths` loop).
//! See `indexes.rs`'s module doc for the wire shape and the three Foundation/ICU/filesystem
//! boundary decisions this port draws (initial `NSString.standardizingPath`, symlink resolution,
//! ASCII-fold-approximated root-alias case-insensitive matching).
//!
//! # `normalizeUserInputPath` dead-code trace (referenced by `indexes.rs`'s boundary note 1)
//!
//! `PathMatcher.locate` computes `trimmedPath` as:
//! ```swift
//! let trimmedPath = raw.hasPrefix("/") ? raw : normalizeUserInputPath(raw, snapshot: snapshot)
//! ```
//! `normalizeUserInputPath(path:snapshot:)`'s entire body is gated by `if trimmed.hasPrefix("/")`
//! after re-trimming `path` (a no-op here, since `raw` is already
//! `.trimmingCharacters(in: .whitespacesAndNewlines)`-clean). Because this call site only ever
//! reaches `normalizeUserInputPath` when `raw` does NOT start with `/` (the ternary's `else`
//! branch), that internal `hasPrefix("/")` check is always `false` for every call `locate` makes,
//! so the function always returns `trimmed` (== `raw`) unchanged. `trimmedPath == raw` always,
//! for both the absolute and relative branches. This is WHY the wire only needs one
//! `standardized_path = StandardizedPath.absolute(raw)` string per query.
//!
//! # Tie-break determinism note (read before trusting a specific winner on tied fixtures)
//!
//! Several Swift ladder stages fall back, once their EXPLICIT tie-break criteria (selected file,
//! selected root, shallower depth, higher score) are exhausted, to "whichever candidate the
//! iteration happened to visit first" -- and that iteration is over a Swift `Dictionary`
//! (`findSingleComponentMatch`'s `byFileName` bucket scan when no extension is given,
//! `findStrictSuffixMatch`'s `candMap`, `candidatesFor`'s `fileMap.values`, and
//! `findBestMatchWithOneMissingComponent`/`gatherAllFolderAndFileItems`'s
//! `filesByFullPath`/`foldersByFullPath`). Swift's own `Dictionary` iteration order is NOT
//! reproducible across process launches (per-process randomized hash seeding) -- so on a genuine
//! tie (identical score, identical depth, identical selection status), Swift itself does not
//! commit to a specific answer; asserting bit-identical parity against ONE Swift run's incidental
//! answer would be asserting against a coin flip, not a specification. Every ladder stage below
//! therefore adds ONE more, fully deterministic tie-break after porting all of Swift's EXPLICIT
//! criteria: ascending `full_path` (UTF-8 byte order). The differential test suite is built to
//! avoid feeding the corpus genuine unresolvable ties (every fixture has at least one
//! distinguishing signal -- selection, depth, or score); a small number of deliberately-tied
//! fixtures exist ONLY to prove Rust's own tie-break is stable and deterministic across repeated
//! runs, not to assert equality against a specific Swift process's answer.

use super::indexes::{
    self, DecodedFile, DecodedFolder, DecodedSnapshot, PathMatchResolveError,
    PathMatchResolveLocation, PathMatchResolveRequestV1, PathMatchResolveResultV1,
};
use super::score::{self, PooledComponent};
use std::collections::HashSet;

// ---- pure path helpers (ported verbatim from PathMatcher.swift; no Foundation dependency in the
// Swift source either -- see `indexes.rs` boundary note 1) --------------------------------------

/// Mirrors `PathMatcher.standardizePathFast`.
pub(crate) fn standardize_path_fast(input: &str) -> String {
    if input.is_empty() {
        return String::new();
    }
    let is_absolute = input.starts_with('/');
    let mut stack: Vec<&str> = Vec::new();
    for seg in input.split('/').filter(|s| !s.is_empty()) {
        match seg {
            "." => continue,
            ".." => {
                if !stack.is_empty() {
                    stack.pop();
                } else if !is_absolute {
                    stack.push("..");
                }
            }
            _ => stack.push(seg),
        }
    }
    if is_absolute {
        if stack.is_empty() {
            "/".to_owned()
        } else {
            format!("/{}", stack.join("/"))
        }
    } else {
        stack.join("/")
    }
}

/// Mirrors `PathMatcher.isUnder`.
pub(crate) fn is_under(path: &str, root: &str) -> bool {
    let p2 = standardize_path_fast(path);
    let r2 = standardize_path_fast(root);
    if p2 == r2 {
        return true;
    }
    if r2.is_empty() {
        return false;
    }
    if let Some(rest) = p2.strip_prefix(&r2) {
        if rest.is_empty() {
            return true;
        }
        return rest.starts_with('/');
    }
    false
}

/// Mirrors `StandardizedPath.relative` (`RepoPromptWorkspaceCore`) -- pure lexical `.`/`..`
/// collapse, no Foundation dependency in the Swift source.
pub(crate) fn standardized_relative(path: &str) -> String {
    let trimmed = path.trim_matches('/');
    if trimmed.is_empty() || trimmed == "." {
        return String::new();
    }
    let mut components: Vec<&str> = Vec::new();
    for component in trimmed.split('/').filter(|s| !s.is_empty()) {
        match component {
            "." => continue,
            ".." => {
                if let Some(&last) = components.last() {
                    if last != ".." {
                        components.pop();
                        continue;
                    }
                }
                components.push(component);
            }
            _ => components.push(component),
        }
    }
    components.join("/")
}

/// Mirrors `PathMatcher.containsParentTraversal`.
fn contains_parent_traversal(relative_path: &str) -> bool {
    relative_path == ".."
        || relative_path.starts_with("../")
        || relative_path.ends_with("/..")
        || relative_path.contains("/../")
}

/// Mirrors `PathMatcher.appendStandardizedRelativePath`.
fn append_standardized_relative_path(root_path: &str, relative_path: &str) -> String {
    if relative_path.is_empty() {
        return root_path.to_owned();
    }
    if root_path.ends_with('/') {
        format!("{root_path}{relative_path}")
    } else {
        format!("{root_path}/{relative_path}")
    }
}

/// Mirrors `PathMatcher.standardizedLookupPath`. The rare `containsParentTraversal` fallback uses
/// `standardize_path_fast` (pure lexical absolute-path collapse) in place of Swift's
/// `StandardizedPath.absolute` (`NSString.standardizingPath`) -- both are lexical `..`-popping
/// algorithms for an already-`/`-prefixed input with no tilde/system-symlink special-casing
/// involved at this point (the ONE place that matters, the initial raw-input standardization, is
/// already handled Swift-side -- see this module's top doc). See `indexes.rs` boundary note 1.
pub(crate) fn standardized_lookup_path(root_path: &str, relative_path: &str) -> String {
    let normalized_relative_path = standardized_relative(relative_path);
    let joined_path = append_standardized_relative_path(root_path, &normalized_relative_path);
    if !contains_parent_traversal(&normalized_relative_path) {
        return joined_path;
    }
    standardize_path_fast(&joined_path)
}

/// Mirrors `(path as NSString).lastPathComponent` for well-formed standardized absolute paths
/// (no trailing slash except the bare root, no embedded NUL). Pure byte-level `/`-split; safe for
/// the root full paths this port ever receives (already standardized by the app's own root
/// loading, never re-derived by this compute kernel).
pub(crate) fn last_path_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    match trimmed.rsplit_once('/') {
        Some((_, last)) => last,
        None => trimmed,
    }
}

/// Mirrors `standardizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/")`.
fn split_components(standardized_path: &str) -> Vec<&str> {
    standardized_path
        .trim_matches('/')
        .split('/')
        .filter(|s| !s.is_empty())
        .collect()
}

fn ascii_lower_owned(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii() {
                c.to_ascii_lowercase()
            } else {
                c
            }
        })
        .collect()
}

// ---- snapshot-level helpers ---------------------------------------------------------------------

/// Mirrors `PathMatcher.rootsWithSelection`.
fn roots_with_selection(snap: &DecodedSnapshot<'_>) -> HashSet<usize> {
    let mut set = HashSet::new();
    for (ordinal, root) in snap.roots.iter().enumerate() {
        if snap
            .selected_file_full_paths
            .iter()
            .any(|&selected| is_under(selected, root.full_path))
        {
            set.insert(ordinal);
        }
    }
    set
}

/// Mirrors `PathMatcher.aliasRootCandidates`. See `indexes.rs` boundary note 3 (ASCII-fold
/// approximation of `.caseInsensitiveCompare`).
fn alias_root_candidates(component: &str, snap: &DecodedSnapshot<'_>) -> Vec<usize> {
    let key = ascii_lower_owned(component);
    if let Some(canonical) = snap.root_alias_by_name_lower.get(&key) {
        if !canonical.is_empty() {
            return canonical.clone();
        }
    }
    snap.root_alias_by_last_component_lower
        .get(&key)
        .cloned()
        .unwrap_or_default()
}

/// Mirrors `PathMatcher.buildHeadTrimVariants`. Returns `(component slice, bias root ordinal)`
/// pairs; slices borrow from `user_components` (itself borrowed from the query's
/// `standardized_path`), so no allocation beyond the returned `Vec` of pairs.
fn build_head_trim_variants<'a>(
    user_components: &[&'a str],
    first_alias_root: Option<usize>,
    snap: &DecodedSnapshot<'_>,
    allow_leading_root_alias_trim: bool,
    allow_head_trim_aliases: bool,
) -> Vec<(Vec<&'a str>, Option<usize>)> {
    let mut variants: Vec<(Vec<&'a str>, Option<usize>)> = Vec::new();

    if allow_leading_root_alias_trim && first_alias_root.is_some() && user_components.len() > 1 {
        variants.push((user_components[1..].to_vec(), first_alias_root));
    } else if !user_components.is_empty() {
        variants.push((user_components.to_vec(), first_alias_root));
    }

    if !allow_head_trim_aliases || user_components.len() <= 1 || first_alias_root.is_some() {
        return variants;
    }

    for idx in 1..user_components.len() {
        let seg_lower = ascii_lower_owned(user_components[idx]);
        let roots = snap
            .root_alias_by_name_lower
            .get(&seg_lower)
            .filter(|v| !v.is_empty())
            .or_else(|| snap.root_alias_by_last_component_lower.get(&seg_lower));
        let Some(roots) = roots else { continue };
        let remainder_start = idx + 1;
        if remainder_start >= user_components.len() {
            continue;
        }
        let trimmed = &user_components[remainder_start..];
        for &root in roots {
            variants.push((trimmed.to_vec(), Some(root)));
        }
    }

    let mut seen: HashSet<String> = HashSet::new();
    variants
        .into_iter()
        .filter(|(comps, bias)| {
            let bias_key = bias
                .map(|b| b.to_string())
                .unwrap_or_else(|| "all".to_owned());
            let key = format!("{bias_key}|{}", comps.join("/"));
            seen.insert(key)
        })
        .collect()
}

/// Mirrors `PathMatcher.getCandidateRoots`. See `indexes.rs` boundary note 2: the
/// `resolvingSymlinksInPath` retry is not ported (identity for every non-symlinked snapshot, which
/// is every snapshot this pure-compute kernel ever sees). Returns root ordinals in root-table
/// order (Swift collects into a `Set<String>` then `Array(...)`, an UNSPECIFIED order this port
/// deliberately replaces with a deterministic one -- `candidate_roots` is only ever used for
/// unordered membership tests (`contains`) or as an explicit iteration Swift ALSO does not order
/// meaningfully beyond "try each root", so this substitution changes no observable outcome).
fn candidate_roots(standardized_path: &str, snap: &DecodedSnapshot<'_>) -> Vec<usize> {
    (0..snap.roots.len())
        .filter(|&ord| is_under(standardized_path, snap.roots[ord].full_path))
        .collect()
}

fn file_by_full_path<'a>(
    snap: &'a DecodedSnapshot<'_>,
    path: &str,
) -> Option<(usize, &'a DecodedFile<'a>)> {
    snap.files
        .iter()
        .enumerate()
        .find(|(_, f)| f.full_path == path)
}

fn folder_by_full_path<'a>(
    snap: &'a DecodedSnapshot<'_>,
    path: &str,
) -> Option<(usize, &'a DecodedFolder<'a>)> {
    snap.folders
        .iter()
        .enumerate()
        .find(|(_, f)| f.full_path == path)
}

fn location_from_file(snap: &DecodedSnapshot<'_>, ordinal: usize) -> PathMatchResolveLocation {
    let file = &snap.files[ordinal];
    PathMatchResolveLocation {
        root_ordinal: file.root_ordinal as u64,
        corrected_path: file.relative_path.to_owned(),
    }
}

fn location_from_folder(snap: &DecodedSnapshot<'_>, ordinal: usize) -> PathMatchResolveLocation {
    let folder = &snap.folders[ordinal];
    PathMatchResolveLocation {
        root_ordinal: folder.root_ordinal as u64,
        corrected_path: folder.relative_path.to_owned(),
    }
}

fn depth_of(relative_path: &str) -> usize {
    relative_path.split('/').filter(|s| !s.is_empty()).count()
}

// ---- single-component match --------------------------------------------------------------------

/// Mirrors `PathMatcher.findSingleComponentMatch`. `name_canonical` is
/// `PathMatchIndexes.canonical(name, caseSensitive)`, precomputed Swift-side (see `indexes.rs`).
fn find_single_component_match(
    name_canonical: &str,
    exact_match_only: bool,
    snap: &DecodedSnapshot<'_>,
) -> Option<PathMatchResolveLocation> {
    let threshold = if exact_match_only { 0.9999 } else { 0.9 };
    let roots_sel = roots_with_selection(snap);

    // 1) exact name matches via byFileName
    if let Some(matches) = snap.by_file_name.get(name_canonical) {
        if matches.len() == 1 {
            return Some(location_from_file(snap, matches[0]));
        } else if matches.len() > 1 {
            let mut sorted = matches.clone();
            sorted.sort_by(|&l, &r| {
                let lf = &snap.files[l];
                let rf = &snap.files[r];
                let l_sel = snap.selected_file_full_paths.contains(lf.full_path);
                let r_sel = snap.selected_file_full_paths.contains(rf.full_path);
                if l_sel != r_sel {
                    return r_sel.cmp(&l_sel); // selected first
                }
                let l_root_sel = roots_sel.contains(&lf.root_ordinal);
                let r_root_sel = roots_sel.contains(&rf.root_ordinal);
                if l_root_sel != r_root_sel {
                    return r_root_sel.cmp(&l_root_sel);
                }
                let l_depth = depth_of(lf.relative_path);
                let r_depth = depth_of(rf.relative_path);
                if l_depth != r_depth {
                    return l_depth.cmp(&r_depth);
                }
                lf.full_path.cmp(rf.full_path)
            });
            return Some(location_from_file(snap, sorted[0]));
        }
    }

    // 2) fuzzy approach bounded by indexes
    let mut candidates: Vec<usize> = Vec::new();
    let ext = extension_of(name_canonical);
    if !ext.is_empty() {
        if let Some(by_ext) = snap.by_extension.get(ext) {
            candidates.extend_from_slice(by_ext);
        }
    } else if !exact_match_only {
        let canon_fc = score::first_alnum_lowered_byte(name_canonical);
        // No length-diff prefilter here (Swift's `abs(canon.count - k.count) > 6` uses Swift
        // grapheme count; approximating with scalar count risks a false-negative divergence on
        // non-ASCII fixtures for a PURE performance prefilter that never affects correctness --
        // the real `similarityScoreMax(...) >= threshold` check below is authoritative either
        // way. Dropping it only means Rust scores a superset of Swift's candidate pool, capped by
        // the same 12000-candidate bound Swift itself uses).
        let mut added = 0usize;
        for (&_key, group) in snap.by_file_name.iter() {
            if let Some(fc) = canon_fc {
                let Some(&first) = group.first() else {
                    continue;
                };
                let Some(kfc) = score::first_alnum_lowered_byte(snap.files[first].name_canonical)
                else {
                    continue;
                };
                if kfc != fc {
                    continue;
                }
            }
            candidates.extend_from_slice(group);
            added += group.len();
            if added >= 12000 {
                break;
            }
        }
    }

    if candidates.is_empty() {
        return None;
    }

    let mut passing: Vec<(f64, usize)> = Vec::new();
    for &ord in &candidates {
        let f1 = snap.files[ord].name_canonical;
        let gate = name_canonical.len().max(f1.len());
        let sim =
            score::similarity_score_max(name_canonical, f1, threshold, gate, snap.case_sensitive);
        if sim >= threshold {
            passing.push((sim, ord));
        }
    }
    if passing.is_empty() {
        return None;
    }
    if passing.len() == 1 {
        return Some(location_from_file(snap, passing[0].1));
    }

    passing.sort_by(|&(l_score, l), &(r_score, r)| {
        let lf = &snap.files[l];
        let rf = &snap.files[r];
        let l_sel = snap.selected_file_full_paths.contains(lf.full_path);
        let r_sel = snap.selected_file_full_paths.contains(rf.full_path);
        if l_sel != r_sel {
            return r_sel.cmp(&l_sel);
        }
        let l_root_sel = roots_sel.contains(&lf.root_ordinal);
        let r_root_sel = roots_sel.contains(&rf.root_ordinal);
        if l_root_sel != r_root_sel {
            return r_root_sel.cmp(&l_root_sel);
        }
        let l_depth = depth_of(lf.relative_path);
        let r_depth = depth_of(rf.relative_path);
        if l_depth == r_depth {
            // Swift compares scores descending here with NO further explicit tiebreak; Rust adds
            // `full_path` ascending as the final deterministic tiebreak -- see this module's top
            // doc.
            return r_score
                .partial_cmp(&l_score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| lf.full_path.cmp(rf.full_path));
        }
        l_depth.cmp(&r_depth)
    });
    Some(location_from_file(snap, passing[0].1))
}

/// Mirrors `(name as NSString).pathExtension.lowercased()` applied to an already-canonical (and
/// therefore already ASCII-lowercased-or-case-preserved-per-policy) name: the last `.`-delimited
/// segment when one exists and isn't the whole string.
fn extension_of(name: &str) -> &str {
    match name.rfind('.') {
        Some(idx) if idx > 0 && idx + 1 < name.len() => &name[idx + 1..],
        _ => "",
    }
}

// ---- multi-component match ----------------------------------------------------------------------

/// Mirrors `PathMatcher.findStrictSuffixMatch`. `user_components_cleaned_lower` are the query's
/// `cleaned(component).lowercased()` pooled components (see `indexes.rs`); `user_components_len`
/// is used only for the depth-based score formula.
fn find_strict_suffix_match(
    user_last_canonical: &str,
    user_last_two_canonical: Option<&str>,
    user_components_cleaned_lower: &[PooledComponent<'_>],
    snap: &DecodedSnapshot<'_>,
) -> Option<usize> {
    let mut seen: HashSet<usize> = HashSet::new();
    let mut candidates: Vec<usize> = Vec::new();
    if let Some(group) = snap.by_file_name.get(user_last_canonical) {
        for &ord in group {
            if seen.insert(ord) {
                candidates.push(ord);
            }
        }
    }
    if let Some(last_two) = user_last_two_canonical {
        if let Some(group) = snap.by_last_two.get(last_two) {
            for &ord in group {
                if seen.insert(ord) {
                    candidates.push(ord);
                }
            }
        }
    }

    let n = user_components_cleaned_lower.len();
    let mut best: Option<usize> = None;
    let mut best_score = 0.0_f64;
    for &ord in &candidates {
        let file = &snap.files[ord];
        if file.components.len() < n {
            continue;
        }
        let file_suffix = &file.components[file.components.len() - n..];
        let all_match =
            (0..n).all(|i| user_components_cleaned_lower[i].text == file_suffix[i].text);
        if !all_match {
            continue;
        }
        let score = (n * 2) as f64 - (file.components.len() - n) as f64;
        // Mirrors Swift exactly: `bestScore` starts at `0.0` and the FIRST assignment still
        // requires `score > bestScore` -- a candidate whose own score is `<= 0.0` (a very deep
        // file matched by a short suffix) is never accepted, even when no candidate has been
        // chosen yet. (`best.is_none()` must NOT be an alternate acceptance path here.)
        if score > best_score {
            best_score = score;
            best = Some(ord);
        } else if score == best_score {
            if let Some(current_best) = best {
                let current_is_selected = snap.selected_file_full_paths.contains(file.full_path);
                let best_is_selected = snap
                    .selected_file_full_paths
                    .contains(snap.files[current_best].full_path);
                if current_is_selected && !best_is_selected {
                    best = Some(ord);
                }
            }
        }
    }
    best
}

/// Mirrors `PathMatcher.lastComponentExists(in snapshot:lastComponent:threshold:)`. Always `true`
/// when indexes can't preconfirm existence -- matches Swift's own permissive fallback verbatim.
fn last_component_exists(last_component_canonical: &str, snap: &DecodedSnapshot<'_>) -> bool {
    if last_component_canonical.is_empty() {
        return false;
    }
    if snap
        .by_file_name
        .get(last_component_canonical)
        .is_some_and(|v| !v.is_empty())
    {
        return true;
    }
    let ext = extension_of(last_component_canonical);
    if !ext.is_empty() && snap.by_extension.get(ext).is_some_and(|v| !v.is_empty()) {
        return true;
    }
    true
}

/// One candidate item -- mirrors `AnyItem`.
enum Item {
    File(usize),
    Folder(usize),
}

impl Item {
    fn root_ordinal(&self, snap: &DecodedSnapshot<'_>) -> usize {
        match self {
            Item::File(ord) => snap.files[*ord].root_ordinal,
            Item::Folder(ord) => snap.folders[*ord].root_ordinal,
        }
    }

    fn components<'a>(&self, snap: &'a DecodedSnapshot<'_>) -> &'a [PooledComponent<'a>] {
        match self {
            Item::File(ord) => &snap.files[*ord].components,
            Item::Folder(ord) => &snap.folders[*ord].components,
        }
    }

    fn full_path<'a>(&self, snap: &'a DecodedSnapshot<'_>) -> &'a str {
        match self {
            Item::File(ord) => snap.files[*ord].full_path,
            Item::Folder(ord) => snap.folders[*ord].full_path,
        }
    }
}

/// Mirrors `PathMatcher.candidatesFor`. `relevant_last_canonical`/`relevant_last_two_canonical`
/// are the CANONICAL forms of the suffix-limited query's last one/two components (used as index
/// keys, exactly like `findStrictSuffixMatch`); `prev_component_canonical` is the canonical form
/// of the second-to-last relevant component (used for the folder-candidate bucket).
fn candidates_for(
    relevant_last_canonical: &str,
    relevant_last_two_canonical: Option<&str>,
    relevant_ext: &str,
    prev_component_canonical: Option<&str>,
    snap: &DecodedSnapshot<'_>,
) -> Vec<Item> {
    let mut seen: HashSet<usize> = HashSet::new();
    let mut file_ordinals: Vec<usize> = Vec::new();

    if let Some(group) = snap.by_file_name.get(relevant_last_canonical) {
        for &ord in group {
            if seen.insert(ord) {
                file_ordinals.push(ord);
            }
        }
    }
    if let Some(last_two) = relevant_last_two_canonical {
        if let Some(group) = snap.by_last_two.get(last_two) {
            for &ord in group {
                if seen.insert(ord) {
                    file_ordinals.push(ord);
                }
            }
        }
    }
    if !relevant_ext.is_empty() {
        if let Some(ext_group) = snap.by_extension.get(relevant_ext) {
            if file_ordinals.is_empty() {
                let mut seen2: HashSet<usize> = HashSet::new();
                for &ord in ext_group {
                    if seen2.insert(ord) {
                        file_ordinals.push(ord);
                    }
                }
            } else {
                let ext_set: HashSet<usize> = ext_group.iter().copied().collect();
                file_ordinals.retain(|ord| ext_set.contains(ord));
            }
        }
    }

    let mut result: Vec<Item> = file_ordinals.into_iter().map(Item::File).collect();

    if let Some(prev) = prev_component_canonical {
        if let Some(folders) = snap.folders_by_last_component.get(prev) {
            for &ord in folders {
                result.push(Item::Folder(ord));
            }
        }
    }

    result
}

/// Mirrors `PathMatcher.fuzzyMatchWithSuffixLimit`. `user_components_cleaned_lower` is the FULL
/// query component array (cleaned+lowered); `suffix_count` selects the tail actually scored.
/// `user_last_canonical`/`user_last_two_canonical`/`user_ext`/`user_prev_canonical` are the
/// canonical forms `candidates_for` needs, derived from the SAME suffix window by the caller.
#[allow(clippy::too_many_arguments)]
fn fuzzy_match_with_suffix_limit(
    user_components_cleaned_lower: &[PooledComponent<'_>],
    suffix_count: usize,
    user_last_canonical: &str,
    user_last_two_canonical: Option<&str>,
    user_ext: &str,
    user_prev_canonical: Option<&str>,
    exact_match_only: bool,
    snap: &DecodedSnapshot<'_>,
) -> Option<PathMatchResolveLocation> {
    let threshold = if exact_match_only { 0.9999 } else { 0.9 };
    let n = user_components_cleaned_lower.len();
    let start = n.saturating_sub(suffix_count);
    let relevant = &user_components_cleaned_lower[start..];

    let candidates = candidates_for(
        user_last_canonical,
        user_last_two_canonical,
        user_ext,
        user_prev_canonical,
        snap,
    );
    let roots_sel = roots_with_selection(snap);

    let mut best_score = f64::NEG_INFINITY;
    let mut best_item: Option<Item> = None;

    for item in candidates {
        let total_component_count = item.components(snap).len();
        let tail_start = total_component_count.saturating_sub(relevant.len());
        let tail = &item.components(snap)[tail_start.min(total_component_count)..];
        if tail.len() != relevant.len() {
            continue;
        }
        let Some(raw_score) =
            score::weighted_component_score(relevant, total_component_count, tail, threshold)
        else {
            continue;
        };
        let root_sel = roots_sel.contains(&item.root_ordinal(snap));
        let adjusted = raw_score + if root_sel { 0.5 } else { 0.0 };

        if adjusted > best_score {
            best_score = adjusted;
            best_item = Some(item);
        } else if adjusted == best_score {
            // Swift's explicit tie-break: prefer a currently-selected FILE over a non-selected
            // one (decided either way -- "current selected" takes it, "existing selected" keeps
            // it -- since Swift's own `if currentIsSelected, !existingIsSelected` only mutates in
            // the first case, implicitly leaving `bestItem` as the incumbent in every other case,
            // including "existing selected, current not"). When selection status doesn't decide
            // (both/neither File, or either side a Folder), fall through to the deterministic
            // `full_path`-ascending tiebreak -- see this module's top doc.
            let mut take_new = false;
            let mut decided = false;
            if let (Item::File(current_ord), Some(Item::File(existing_ord))) = (&item, &best_item) {
                let current_is_selected = snap
                    .selected_file_full_paths
                    .contains(snap.files[*current_ord].full_path);
                let existing_is_selected = snap
                    .selected_file_full_paths
                    .contains(snap.files[*existing_ord].full_path);
                if current_is_selected != existing_is_selected {
                    take_new = current_is_selected;
                    decided = true;
                }
            }
            if !decided {
                take_new = match &best_item {
                    Some(existing) => item.full_path(snap) < existing.full_path(snap),
                    None => true,
                };
            }
            if take_new {
                best_item = Some(item);
            }
        }
    }

    best_item.map(|item| match item {
        Item::File(ord) => location_from_file(snap, ord),
        Item::Folder(ord) => location_from_folder(snap, ord),
    })
}

/// Mirrors `PathMatcher.findBestMultiComponentMatch`. `user_components_canonical`/
/// `user_components_cleaned_lower` are the (possibly alias-trimmed) `compsForMatch` array in both
/// derived forms, index-aligned.
fn find_best_multi_component_match(
    user_components_canonical: &[&str],
    user_components_cleaned_lower: &[PooledComponent<'_>],
    exact_match_only: bool,
    snap: &DecodedSnapshot<'_>,
) -> Option<PathMatchResolveLocation> {
    let n = user_components_canonical.len();
    debug_assert_eq!(n, user_components_cleaned_lower.len());
    if n == 0 {
        return None;
    }
    let last_canonical = user_components_canonical[n - 1];
    let last_two_canonical = if n >= 2 {
        Some(concat_last_two(user_components_canonical))
    } else {
        None
    };
    let ext = extension_of(last_canonical);
    let prev_canonical = if n >= 2 {
        Some(user_components_canonical[n - 2])
    } else {
        None
    };

    // 1) strict suffix
    if let Some(hit) = find_strict_suffix_match(
        last_canonical,
        last_two_canonical.as_deref(),
        user_components_cleaned_lower,
        snap,
    ) {
        return Some(location_from_file(snap, hit));
    }

    // 2) quick pre-check of final component
    if !last_component_exists(last_canonical, snap) {
        return None;
    }

    // 3) suffix-3, 4) suffix-5, 5) whole path.
    //
    // NOTE on `user_last_canonical`/`user_last_two_canonical`/`user_ext`/`user_prev_canonical`:
    // these are ALWAYS the full array's own last one/two components, regardless of
    // `suffix_count`. This mirrors Swift's own `candidatesFor`, whose `relevantComps =
    // userComponents.suffix(suffixCount)` -- the last element and last-two-elements of ANY
    // non-empty suffix window of an array are, respectively, the array's own last element and
    // last-two elements (a suffix's suffix is still anchored at the same end). So these four
    // index-key inputs are provably window-independent; only `relevant`
    // (`user_components_cleaned_lower[start..]`, computed INSIDE `fuzzy_match_with_suffix_limit`
    // from `suffix_count`) actually varies across the three calls below.
    if let Some(result) = fuzzy_match_with_suffix_limit(
        user_components_cleaned_lower,
        3,
        last_canonical,
        last_two_canonical.as_deref(),
        ext,
        prev_canonical,
        exact_match_only,
        snap,
    ) {
        return Some(result);
    }

    if n > 3 {
        if let Some(result) = fuzzy_match_with_suffix_limit(
            user_components_cleaned_lower,
            5,
            last_canonical,
            last_two_canonical.as_deref(),
            ext,
            prev_canonical,
            exact_match_only,
            snap,
        ) {
            return Some(result);
        }
    }

    fuzzy_match_with_suffix_limit(
        user_components_cleaned_lower,
        n,
        last_canonical,
        last_two_canonical.as_deref(),
        ext,
        prev_canonical,
        exact_match_only,
        snap,
    )
}

/// Builds the RAW (uncleaned) "comp[n-2]/comp[n-1]" text Swift feeds into `canonical(...)` for the
/// `byLastTwo` index key -- NOT usable here since we only have the already-canonical per-component
/// forms on the query side. This concatenates the CANONICAL forms with `/` instead. This is safe
/// because `canonical()` is applied per-character with no cross-character state (ASCII fast path:
/// per-byte filter+lower; Unicode slow path: per-scalar fold) and `/` (0x2F) is itself in the
/// allowed-ASCII set and passes through canonicalization unchanged, so
/// `canonical(a) + "/" + canonical(b) == canonical(a + "/" + b)` for the OVERWHELMING common case.
/// The one theoretical exception -- NFC canonical composition merging a trailing combining mark of
/// `a` with a leading character of `b` across the `/` boundary -- cannot occur here because `/` is
/// not a combining character and NFC composition never crosses a non-combining boundary character.
/// File-table `last_two_canonical` (see `indexes.rs`) is still Swift-precomputed directly from the
/// real joined-then-canonicalized string, so INDEX KEYS built at decode time are exact; this
/// reconstruction is used ONLY for building a QUERY-side lookup key to compare against those exact
/// keys, and is provably equivalent to the real thing for the reason above.
fn concat_last_two(components: &[&str]) -> String {
    let n = components.len();
    format!("{}/{}", components[n - 2], components[n - 1])
}

/// Mirrors `PathMatcher.findAbsoluteParentQualifiedTail`.
fn find_absolute_parent_qualified_tail(
    user_components: &[&str],
    min_tail: usize,
    max_tail: usize,
    snap: &DecodedSnapshot<'_>,
) -> Option<PathMatchResolveLocation> {
    if user_components.len() < min_tail {
        return None;
    }
    let roots_sel = roots_with_selection(snap);
    let min_n = min_tail.max(2);
    let max_n = max_tail.max(min_n);

    let mut candidates: Vec<usize> = Vec::new();
    for n in min_n..=max_n.min(user_components.len()) {
        let window = &user_components[user_components.len() - n..];
        let parent_rel = window[..window.len() - 1].join("/");
        let file_name = user_components.last().copied().unwrap_or("");
        if parent_rel.is_empty() || file_name.is_empty() {
            continue;
        }
        let standardized_parent_rel = standardized_relative(&parent_rel);
        for root in &snap.roots {
            let folder_abs = standardized_lookup_path(root.full_path, &standardized_parent_rel);
            if folder_by_full_path(snap, &folder_abs).is_some() {
                let file_abs = append_standardized_relative_path(&folder_abs, file_name);
                if let Some((ord, _)) = file_by_full_path(snap, &file_abs) {
                    candidates.push(ord);
                }
            }
        }
        if !candidates.is_empty() {
            break;
        }
    }

    if candidates.is_empty() && user_components.len() >= 2 {
        // Fallback: match by last two components across all files. See this module's top doc for
        // the ASCII-fold approximation of `.lowercased()`/`hasSuffix` used here.
        let lower_suffix =
            ascii_lower_owned(&user_components[user_components.len() - 2..].join("/"));
        for (ord, file) in snap.files.iter().enumerate() {
            if ascii_lower_owned(file.relative_path).ends_with(&lower_suffix) {
                candidates.push(ord);
            }
        }
    }

    if candidates.is_empty() {
        return None;
    }

    candidates.sort_by(|&l, &r| {
        let lf = &snap.files[l];
        let rf = &snap.files[r];
        let l_sel = roots_sel.contains(&lf.root_ordinal);
        let r_sel = roots_sel.contains(&rf.root_ordinal);
        if l_sel != r_sel {
            return r_sel.cmp(&l_sel);
        }
        let l_depth = depth_of(lf.relative_path);
        let r_depth = depth_of(rf.relative_path);
        if l_depth != r_depth {
            return l_depth.cmp(&r_depth);
        }
        lf.full_path.cmp(rf.full_path)
    });
    Some(location_from_file(snap, candidates[0]))
}

/// Mirrors `PathMatcher.findBestMatchWithOneMissingComponent`. Full-scan fallback; benefits most
/// from a Rust port (Swift recomputes `gatherAllFolderAndFileItems` -- ALL files -- on every
/// `skipIndex` iteration; this port does the equivalent scan without the Dictionary-iteration
/// nondeterminism -- see this module's top doc).
fn find_best_match_with_one_missing_component(
    user_components_canonical: &[&str],
    user_components_cleaned_lower: &[PooledComponent<'_>],
    exact_match_only: bool,
    snap: &DecodedSnapshot<'_>,
) -> Option<usize> {
    let n = user_components_cleaned_lower.len();
    if n < 2 {
        return None;
    }
    let threshold = if exact_match_only { 0.9999 } else { 0.85 };
    let mut best: Option<usize> = None;
    let mut best_score = f64::NEG_INFINITY;
    let mut best_depth = usize::MAX;

    for skip_index in 0..n {
        let mut adjusted_cleaned: Vec<&PooledComponent<'_>> = Vec::with_capacity(n - 1);
        for (i, comp) in user_components_cleaned_lower.iter().enumerate() {
            if i != skip_index {
                adjusted_cleaned.push(comp);
            }
        }
        let _ = user_components_canonical; // canonical form not needed by the weighted kernel

        for (ord, file) in snap.files.iter().enumerate() {
            let total = file.components.len();
            let m = adjusted_cleaned.len();
            if total < m {
                continue;
            }
            let tail_start = total - m;
            let tail = &file.components[tail_start..];
            let query_slice: Vec<PooledComponent<'_>> = adjusted_cleaned
                .iter()
                .map(|c| PooledComponent::new(c.text, c.char_count, c.cleaned_byte_len))
                .collect();
            let Some(score) = score::weighted_component_score(&query_slice, total, tail, threshold)
            else {
                continue;
            };
            let penalized = score - 1.25;
            let depth = depth_of(file.relative_path);
            if penalized > best_score || (penalized == best_score && depth < best_depth) {
                best_score = penalized;
                best_depth = depth;
                best = Some(ord);
            }
        }
    }

    best
}

// ---- top-level ladder -----------------------------------------------------------------------

/// Mirrors `PathMatcher.locate`. Returns `None` for every `nil` outcome in the Swift source.
pub(crate) fn resolve_one(
    query_idx: usize,
    snap: &DecodedSnapshot<'_>,
) -> Option<PathMatchResolveLocation> {
    let query = &snap.queries[query_idx];
    let standardized_path = query.standardized_path;
    if standardized_path.is_empty() {
        return None;
    }

    let is_absolute = standardized_path.starts_with('/');
    let user_components = split_components(standardized_path);
    debug_assert_eq!(user_components.len(), query.canonical_components.len());

    let exact_match_only = snap.exact_match_only;

    if is_absolute {
        // 1) direct full match
        if let Some((ord, _)) = file_by_full_path(snap, standardized_path) {
            return Some(location_from_file(snap, ord));
        }

        // 2) candidate roots
        let mut roots = candidate_roots(standardized_path, snap);
        if roots.is_empty() {
            // Symlink-resolved retry: identity in this compute kernel (see this module's top
            // doc + indexes.rs boundary note 2) -- re-running with the same string finds nothing
            // new, so this is a documented no-op rather than a literal retry.
            roots = candidate_roots(standardized_path, snap);
        }
        if roots.is_empty() {
            if !exact_match_only && snap.allow_absolute_suffix_fallback {
                let max_tail = 20.min(user_components.len());
                if let Some(hit) =
                    find_absolute_parent_qualified_tail(&user_components, 2, max_tail, snap)
                {
                    return Some(hit);
                }
            }
            return None;
        }

        // 3) parent-folder optimization
        if user_components.len() > 1 {
            let file_name = user_components[user_components.len() - 1];
            let parent_rel = user_components[..user_components.len() - 1].join("/");
            let standardized_parent_rel = standardized_relative(&parent_rel);
            for &root_ord in &roots {
                let root = &snap.roots[root_ord];
                let folder_abs = standardized_lookup_path(root.full_path, &standardized_parent_rel);
                if folder_by_full_path(snap, &folder_abs).is_some() {
                    let expected_file_path =
                        append_standardized_relative_path(&folder_abs, file_name);
                    if let Some((ord, _)) = file_by_full_path(snap, &expected_file_path) {
                        return Some(location_from_file(snap, ord));
                    }
                }
            }
        }

        if exact_match_only {
            return None;
        }

        // 4) fuzzy single vs. multi component
        if user_components.len() == 1 {
            let result =
                find_single_component_match(query.canonical_components[0], exact_match_only, snap)?;
            if !roots.is_empty() && !roots.contains(&(result.root_ordinal as usize)) {
                return None;
            }
            return Some(result);
        }
        let multi = find_best_multi_component_match(
            &query.canonical_components,
            &query.cleaned_lower_components,
            exact_match_only,
            snap,
        )?;
        if !roots.is_empty() && !roots.contains(&(multi.root_ordinal as usize)) {
            return None;
        }
        return Some(multi);
    }

    // ─── RELATIVE PATH LOGIC ───
    let alias_root = if user_components.is_empty() {
        None
    } else {
        alias_root_candidates(user_components[0], snap)
            .first()
            .copied()
    };

    let (rel_components_canonical, rel_components_cleaned_lower): (
        Vec<&str>,
        Vec<PooledComponent<'_>>,
    ) = if alias_root.is_some() && user_components.len() > 1 {
        (
            query.canonical_components[1..].to_vec(),
            query.cleaned_lower_components[1..]
                .iter()
                .map(|c| PooledComponent::new(c.text, c.char_count, c.cleaned_byte_len))
                .collect(),
        )
    } else {
        (
            query.canonical_components.clone(),
            query
                .cleaned_lower_components
                .iter()
                .map(|c| PooledComponent::new(c.text, c.char_count, c.cleaned_byte_len))
                .collect(),
        )
    };

    let roots_sel = roots_with_selection(snap);

    let variants = build_head_trim_variants(
        &user_components,
        alias_root,
        snap,
        snap.allow_leading_root_alias_trim,
        snap.allow_head_trim_aliases,
    );

    // Pass 1: strict absolute-candidate matches for each variant
    for (variant_comps, bias_root) in &variants {
        if variant_comps.is_empty() {
            continue;
        }
        let variant_rel = variant_comps.join("/");
        let standardized_variant_rel = standardized_relative(&variant_rel);
        if let Some(bias) = bias_root {
            let root = &snap.roots[*bias];
            let abs = standardized_lookup_path(root.full_path, &standardized_variant_rel);
            if let Some((ord, _)) = file_by_full_path(snap, &abs) {
                return Some(location_from_file(snap, ord));
            }
        } else {
            let mut ordered: Vec<usize> = (0..snap.roots.len()).collect();
            ordered.sort_by(|&l, &r| {
                let l_sel = roots_sel.contains(&l);
                let r_sel = roots_sel.contains(&r);
                if l_sel != r_sel {
                    return r_sel.cmp(&l_sel);
                }
                if let Some(alias) = alias_root {
                    let l_alias = l == alias;
                    let r_alias = r == alias;
                    if l_alias != r_alias {
                        return r_alias.cmp(&l_alias);
                    }
                }
                snap.roots[l].full_path.cmp(snap.roots[r].full_path)
            });
            for root_ord in ordered {
                let root = &snap.roots[root_ord];
                let abs = standardized_lookup_path(root.full_path, &standardized_variant_rel);
                if let Some((ord, _)) = file_by_full_path(snap, &abs) {
                    return Some(location_from_file(snap, ord));
                }
            }
        }
    }

    // Pass 2: parent-folder quick check for each variant
    for (variant_comps, bias_root) in &variants {
        if variant_comps.len() <= 1 {
            continue;
        }
        let file_name = variant_comps[variant_comps.len() - 1];
        let folder_rel = standardized_relative(&variant_comps[..variant_comps.len() - 1].join("/"));
        let ordered: Vec<usize> = if let Some(bias) = bias_root {
            std::iter::once(*bias)
                .chain((0..snap.roots.len()).filter(|&r| r != *bias))
                .collect()
        } else {
            (0..snap.roots.len()).collect()
        };
        for root_ord in ordered {
            let root = &snap.roots[root_ord];
            let folder_abs = standardized_lookup_path(root.full_path, &folder_rel);
            if folder_by_full_path(snap, &folder_abs).is_some() {
                let expected_file_path = append_standardized_relative_path(&folder_abs, file_name);
                if let Some((ord, _)) = file_by_full_path(snap, &expected_file_path) {
                    return Some(location_from_file(snap, ord));
                }
            }
        }
    }

    if exact_match_only {
        return None;
    }

    if alias_root.is_some() && snap.allow_leading_root_alias_trim {
        return None;
    }

    // 3) fuzzy logic on the original (untrimmed/alias-processed) components
    if rel_components_canonical.len() == 1 {
        return find_single_component_match(rel_components_canonical[0], exact_match_only, snap);
    }
    if let Some(result) = find_best_multi_component_match(
        &rel_components_canonical,
        &rel_components_cleaned_lower,
        exact_match_only,
        snap,
    ) {
        return Some(result);
    }

    // 4) last resort: tolerate a single missing component
    find_best_match_with_one_missing_component(
        &rel_components_canonical,
        &rel_components_cleaned_lower,
        exact_match_only,
        snap,
    )
    .map(|ord| location_from_file(snap, ord))
}

// ---- service --------------------------------------------------------------------------------

/// Batch entry mirroring `PathMatchWorker.locateMany`'s serial `for userPath in userPaths` loop
/// over one shared, immutable snapshot decoded once per call.
#[derive(Default)]
pub struct PathMatchResolveService;

impl PathMatchResolveService {
    pub fn compute(
        &self,
        request: &PathMatchResolveRequestV1,
    ) -> Result<PathMatchResolveResultV1, PathMatchResolveError> {
        self.compute_with_cancellation(request, None)
    }

    pub fn compute_with_cancellation(
        &self,
        request: &PathMatchResolveRequestV1,
        cancellation: Option<&crate::LeafCancellation>,
    ) -> Result<PathMatchResolveResultV1, PathMatchResolveError> {
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(PathMatchResolveError::Cancelled);
        }
        let snap = indexes::decode(request)?;
        let mut locations = Vec::with_capacity(snap.queries.len());
        for idx in 0..snap.queries.len() {
            if idx % 256 == 0 && cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
                return Err(PathMatchResolveError::Cancelled);
            }
            locations.push(resolve_one(idx, &snap));
        }
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(PathMatchResolveError::Cancelled);
        }
        Ok(PathMatchResolveResultV1 { locations })
    }
}

#[cfg(test)]
mod resolve_tests {
    use super::super::contract::{PATH_RESOLVE_CONTRACT_VERSION_V1, QUERY_STRIDE};
    use super::*;

    #[derive(Default)]
    struct Fixture {
        req: PathMatchResolveRequestV1,
    }

    fn ascii_component(text: &str) -> (&str, u64, u64) {
        (text, text.chars().count() as u64, text.len() as u64)
    }

    impl Fixture {
        fn new() -> Self {
            let mut f = Self::default();
            f.req.contract_version = PATH_RESOLVE_CONTRACT_VERSION_V1;
            f
        }

        fn options(mut self, exact_match_only: bool, allow_absolute_suffix_fallback: bool) -> Self {
            self.req.exact_match_only = exact_match_only;
            self.req.allow_leading_root_alias_trim = true;
            self.req.allow_head_trim_aliases = true;
            self.req.allow_absolute_suffix_fallback = allow_absolute_suffix_fallback;
            self
        }

        fn case_sensitive(mut self, value: bool) -> Self {
            self.req.case_sensitive = value;
            self
        }

        fn add_root(&mut self, full_path: &str, name: &str) -> u64 {
            self.req.push_root(full_path, name)
        }

        fn add_selected(&mut self, full_path: &str) {
            self.req.push_selected_file_full_path(full_path);
        }

        fn canon(&self, s: &str) -> String {
            if self.req.case_sensitive {
                s.to_owned()
            } else {
                s.to_ascii_lowercase()
            }
        }

        fn add_file(&mut self, full_path: &str, relative_path: &str, root_ordinal: u64) -> u64 {
            let name = full_path.rsplit('/').next().unwrap_or(full_path);
            let name_canonical = self.canon(name);
            let ext = match name.rfind('.') {
                Some(idx) if idx > 0 && idx + 1 < name.len() => {
                    name[idx + 1..].to_ascii_lowercase()
                }
                _ => String::new(),
            };
            let comps: Vec<&str> = relative_path.split('/').filter(|s| !s.is_empty()).collect();
            let last_two_canonical = if comps.len() >= 2 {
                self.canon(&format!(
                    "{}/{}",
                    comps[comps.len() - 2],
                    comps[comps.len() - 1]
                ))
            } else {
                String::new()
            };
            let cleaned_lower_comps: Vec<String> =
                comps.iter().map(|c| c.to_ascii_lowercase()).collect();
            let pairs: Vec<(&str, u64, u64)> = cleaned_lower_comps
                .iter()
                .map(|s| ascii_component(s))
                .collect();
            self.req.push_file(
                full_path,
                relative_path,
                root_ordinal,
                &name_canonical,
                &ext,
                &last_two_canonical,
                &pairs,
            )
        }

        fn add_folder(&mut self, full_path: &str, relative_path: &str, root_ordinal: u64) -> u64 {
            let name = full_path.rsplit('/').next().unwrap_or(full_path);
            let name_canonical = self.canon(name);
            let comps: Vec<&str> = relative_path.split('/').filter(|s| !s.is_empty()).collect();
            let cleaned_lower_comps: Vec<String> =
                comps.iter().map(|c| c.to_ascii_lowercase()).collect();
            let pairs: Vec<(&str, u64, u64)> = cleaned_lower_comps
                .iter()
                .map(|s| ascii_component(s))
                .collect();
            self.req.push_folder(
                full_path,
                relative_path,
                root_ordinal,
                &name_canonical,
                &pairs,
            )
        }

        fn add_query(&mut self, standardized_path: &str) -> usize {
            let comps: Vec<&str> = standardized_path
                .trim_matches('/')
                .split('/')
                .filter(|s| !s.is_empty())
                .collect();
            let canonical_owned: Vec<String> = comps.iter().map(|c| self.canon(c)).collect();
            let canonical: Vec<&str> = canonical_owned.iter().map(String::as_str).collect();
            let cleaned_lower_owned: Vec<String> =
                comps.iter().map(|c| c.to_ascii_lowercase()).collect();
            let cleaned_lower: Vec<(&str, u64, u64)> = cleaned_lower_owned
                .iter()
                .map(|s| ascii_component(s))
                .collect();
            self.req
                .push_query(standardized_path, &canonical, &cleaned_lower);
            (self.req.query_words.len() / QUERY_STRIDE) as usize - 1
        }

        fn resolve(&self, query_idx: usize) -> Option<PathMatchResolveLocation> {
            let snap = indexes::decode(&self.req).expect("valid fixture request");
            resolve_one(query_idx, &snap)
        }
    }

    #[test]
    fn direct_full_path_match_wins_absolute() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("/Root/src/App.swift");
        let loc = f.resolve(q).expect("expected a match");
        assert_eq!(loc.root_ordinal, root);
        assert_eq!(loc.corrected_path, "src/App.swift");
    }

    #[test]
    fn absolute_parent_folder_optimization_matches() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_folder("/Root/src", "src", root);
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("/Root/src/App.swift");
        let loc = f.resolve(q).expect("expected a match");
        assert_eq!(loc.corrected_path, "src/App.swift");
    }

    #[test]
    fn relative_alias_qualified_exact_match() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Workspace/Root", "Root");
        f.add_file("/Workspace/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("Root/src/App.swift");
        let loc = f.resolve(q).expect("expected alias-qualified match");
        assert_eq!(loc.corrected_path, "src/App.swift");
    }

    #[test]
    fn relative_plain_exact_match_without_alias() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Workspace/Root", "Root");
        f.add_file("/Workspace/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("src/App.swift");
        let loc = f.resolve(q).expect("expected a match");
        assert_eq!(loc.corrected_path, "src/App.swift");
    }

    #[test]
    fn single_component_exact_index_hit() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("App.swift");
        let loc = f.resolve(q).expect("expected a match");
        assert_eq!(loc.corrected_path, "src/App.swift");
    }

    #[test]
    fn single_component_fuzzy_typo_match() {
        // Separator-fold similarity ("-" vs "_") gives a deterministic sim=1.0 fuzzy hit without
        // depending on Levenshtein-distance-vs-threshold arithmetic for a specific string length.
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file(
            "/Root/src/App-Delegate.swift",
            "src/App-Delegate.swift",
            root,
        );
        let q = f.add_query("App_Delegate.swift");
        let loc = f.resolve(q).expect("expected a fuzzy match");
        assert_eq!(loc.corrected_path, "src/App-Delegate.swift");
    }

    #[test]
    fn single_component_tie_break_prefers_selected_file() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/a/App.swift", "a/App.swift", root);
        f.add_file("/Root/b/App.swift", "b/App.swift", root);
        f.add_selected("/Root/b/App.swift");
        let q = f.add_query("App.swift");
        let loc = f.resolve(q).expect("expected a match");
        assert_eq!(loc.corrected_path, "b/App.swift");
    }

    #[test]
    fn single_component_tie_break_prefers_shallower_depth() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/a/b/App.swift", "a/b/App.swift", root);
        f.add_file("/Root/c/App.swift", "c/App.swift", root);
        let q = f.add_query("App.swift");
        let loc = f.resolve(q).expect("expected a match");
        assert_eq!(loc.corrected_path, "c/App.swift");
    }

    #[test]
    fn strict_suffix_match_beats_fuzzy() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/pkg/src/App.swift", "pkg/src/App.swift", root);
        let q = f.add_query("src/App.swift");
        let loc = f.resolve(q).expect("expected a strict suffix match");
        assert_eq!(loc.corrected_path, "pkg/src/App.swift");
    }

    #[test]
    fn fuzzy_suffix_match_last_three() {
        // "app_utils" vs "app-utils" differ byte-for-byte (so `findStrictSuffixMatch`'s exact
        // cleaned+lowered comparison rejects this candidate), but separator-fold similarity gives
        // a deterministic sim=1.0 once the ladder falls through to `fuzzyMatchWithSuffixLimit`.
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file(
            "/Root/pkg/app-utils/App.swift",
            "pkg/app-utils/App.swift",
            root,
        );
        let q = f.add_query("pkg/app_utils/App.swift");
        let loc = f.resolve(q).expect("expected a fuzzy suffix match");
        assert_eq!(loc.corrected_path, "pkg/app-utils/App.swift");
    }

    #[test]
    fn fuzzy_suffix_root_selection_bonus_breaks_near_tie() {
        let mut f = Fixture::new().options(false, true);
        let root_a = f.add_root("/RootA", "RootA");
        let root_b = f.add_root("/RootB", "RootB");
        f.add_file("/RootA/pkg/src/App.swift", "pkg/src/App.swift", root_a);
        f.add_file("/RootB/pkg/src/App.swift", "pkg/src/App.swift", root_b);
        f.add_selected("/RootB/other/File.swift");
        let q = f.add_query("pkg/src/App.swift");
        let loc = f.resolve(q).expect("expected a match");
        assert_eq!(
            loc.root_ordinal, root_b,
            "selected-root bonus should break the tie toward RootB"
        );
    }

    #[test]
    fn one_missing_component_fallback_matches() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file(
            "/Root/pkg/extra/src/App.swift",
            "pkg/extra/src/App.swift",
            root,
        );
        let q = f.add_query("pkg/src/App.swift");
        let loc = f
            .resolve(q)
            .expect("expected a one-missing-component match");
        assert_eq!(loc.corrected_path, "pkg/extra/src/App.swift");
    }

    #[test]
    fn exact_match_only_rejects_fuzzy_hits() {
        let mut f = Fixture::new().options(true, false);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("Apq.swift");
        assert!(f.resolve(q).is_none());
    }

    #[test]
    fn exact_match_only_still_allows_direct_hit() {
        let mut f = Fixture::new().options(true, false);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("/Root/src/App.swift");
        let loc = f
            .resolve(q)
            .expect("expected a direct match even with exactMatchOnly");
        assert_eq!(loc.corrected_path, "src/App.swift");
    }

    #[test]
    fn absolute_suffix_fallback_matches_when_no_candidate_root() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_folder("/Root/src", "src", root);
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("/Somewhere/Else/src/App.swift");
        let loc = f
            .resolve(q)
            .expect("expected the absolute suffix fallback to match");
        assert_eq!(loc.corrected_path, "src/App.swift");
    }

    #[test]
    fn absolute_suffix_fallback_last_two_component_scan_matches_with_no_folder_records() {
        // No folder records are registered at all, so `find_absolute_parent_qualified_tail`'s
        // primary per-`n` folder-existence loop can never succeed for any `n` -- this exercises
        // ONLY its last-resort "scan every file, compare last-two-components as a lowercased
        // suffix" fallback branch (previously uncovered).
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/pkg/src/App.swift", "pkg/src/App.swift", root);
        let q = f.add_query("/Unrelated/Prefix/src/App.swift");
        let loc = f
            .resolve(q)
            .expect("expected the last-two-component fallback scan to match");
        assert_eq!(loc.corrected_path, "pkg/src/App.swift");
    }

    #[test]
    fn absolute_suffix_fallback_disabled_returns_none() {
        let mut f = Fixture::new().options(false, false);
        let root = f.add_root("/Root", "Root");
        f.add_folder("/Root/src", "src", root);
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("/Somewhere/Else/src/App.swift");
        assert!(f.resolve(q).is_none());
    }

    #[test]
    fn case_sensitive_policy_rejects_case_mismatched_exact_lookup() {
        let mut f = Fixture::new().options(false, true).case_sensitive(true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("app.swift");
        assert!(
            f.resolve(q).is_none(),
            "case-sensitive policy must not case-insensitively match"
        );
    }

    #[test]
    fn case_insensitive_policy_matches_case_mismatched_exact_lookup() {
        let mut f = Fixture::new().options(false, true).case_sensitive(false);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("app.swift");
        let loc = f.resolve(q).expect("expected a case-insensitive match");
        assert_eq!(loc.corrected_path, "src/App.swift");
    }

    #[test]
    fn multi_root_alias_disambiguates() {
        let mut f = Fixture::new().options(false, true);
        let root_a = f.add_root("/A", "AliasA");
        let root_b = f.add_root("/B", "AliasB");
        f.add_file("/A/shared/File.swift", "shared/File.swift", root_a);
        f.add_file("/B/shared/File.swift", "shared/File.swift", root_b);
        let q = f.add_query("AliasB/shared/File.swift");
        let loc = f.resolve(q).expect("expected an alias-qualified match");
        assert_eq!(loc.root_ordinal, root_b);
    }

    #[test]
    fn no_match_returns_none() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        let q = f.add_query("totally/unrelated/Path.rs");
        assert!(f.resolve(q).is_none());
    }

    #[test]
    fn locate_many_batch_resolves_independently() {
        let mut f = Fixture::new().options(false, true);
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        f.add_file("/Root/src/Util.swift", "src/Util.swift", root);
        let q1 = f.add_query("App.swift");
        let q2 = f.add_query("Util.swift");
        let q3 = f.add_query("Missing.swift");
        let service = PathMatchResolveService;
        let result = service
            .compute(&f.req)
            .expect("batch compute should succeed");
        assert_eq!(result.locations.len(), 3);
        assert_eq!(
            result.locations[q1].as_ref().unwrap().corrected_path,
            "src/App.swift"
        );
        assert_eq!(
            result.locations[q2].as_ref().unwrap().corrected_path,
            "src/Util.swift"
        );
        assert!(result.locations[q3].is_none());
    }

    #[test]
    fn rejects_unknown_contract_version() {
        let mut f = Fixture::new().options(false, true);
        f.req.contract_version = 999;
        let root = f.add_root("/Root", "Root");
        f.add_file("/Root/src/App.swift", "src/App.swift", root);
        f.add_query("App.swift");
        let service = PathMatchResolveService;
        assert!(matches!(
            service.compute(&f.req),
            Err(PathMatchResolveError::InvalidRequest(_))
        ));
    }
}
