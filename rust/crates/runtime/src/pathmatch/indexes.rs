//! P3-3 slice-2a: compact snapshot wire (request) for the workspace path-match RESOLUTION
//! PIPELINE (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatcher.swift`'s
//! `locate` ladder, driven by `PathMatchWorker.locateMany` over one immutable snapshot), plus the
//! candidate-bucket indexes (`PathMatchIndexes`: byFileName / byLastTwo / byExtension /
//! foldersByLastComponent) built from that snapshot once per request batch. `resolve.rs` is the
//! ladder itself; this module is the wire shape + decode + index-build step it runs against.
//!
//! # Wire/cleaning scope boundary (read before touching this file -- extends `score.rs`'s doc)
//!
//! `PathMatcher.locate` touches THREE distinct Foundation/ICU/filesystem-dependent primitives
//! beyond the ones `score.rs` already scoped out. Per the same "keep Foundation-dependent
//! decisions on the Swift side, OR port with differential fixtures proving parity" escape hatch
//! slice-1 used, this module draws these lines:
//!
//! 1. **Initial path standardization (`StandardizedPath.absolute`, i.e. `NSString.standardizingPath`)**:
//!    kept Swift-side. The wire carries ONE precomputed string per query --
//!    `standardized_path` -- exactly `StandardizedPath.absolute(PathCharPolicy
//!    .foldHomoglyphsIfNeeded(userPath.trimmingCharacters(in: .whitespacesAndNewlines)))`, matching
//!    `PathMatcher.locate`'s own first few lines byte-for-byte (its `normalizeUserInputPath` call
//!    is DEAD CODE from `locate`'s call site: it only special-cases input starting with `/`, but
//!    `locate` only ever calls it with input that does NOT start with `/`, so it is provably a
//!    same-string passthrough there -- see `resolve.rs`'s module doc for the trace). Everything
//!    downstream of this one string -- splitting into components, joining with a root's
//!    `full_path`, resolving `.`/`..` -- is pure lexical logic with NO Foundation dependency
//!    (`PathMatcher.standardizePathFast`, `StandardizedPath.relative`, and
//!    `PathMatcher.standardizedLookupPath`'s common case are ALL pure Swift already, no NSString
//!    calls), so `resolve.rs` ports those directly and reconstructs every downstream comparison
//!    path itself.
//!
//! 2. **Symlink resolution (`(path as NSString).resolvingSymlinksInPath`)**, used only by
//!    `getCandidateRoots`'s fallback retry when a literal prefix match against every loaded root
//!    fails: NOT ported. `resolve.rs`'s `candidate_roots` treats the symlink-resolved form of a
//!    path as identical to its standardized form. This is exactly Swift's own observed behavior
//!    whenever the queried paths do not correspond to real on-disk symlinks -- true for every
//!    snapshot this compute kernel ever sees (it is a pure function over an in-memory snapshot,
//!    never touching the real filesystem), and therefore true for every differential-test fixture
//!    built from synthetic in-memory roots. A production caller whose workspace root sits behind a
//!    real filesystem symlink and whose typed path resolves only via that symlink is the one
//!    scenario this boundary does not cover; see the top-level report for this slice.
//!
//! 3. **ICU case-insensitive comparison for ROOT-ALIAS matching**
//!    (`aliasRootCandidates`'s `.caseInsensitiveCompare`, and `buildHeadTrimVariants`'s
//!    `Dictionary(grouping:) { $0.name.lowercased() }` / `{ lastPathComponent.lowercased() }`):
//!    approximated with ASCII-only lowercasing (`policy::to_lower_ascii`), NOT full ICU
//!    `.lowercased()`/`.caseInsensitiveCompare`. Root names are virtually always ASCII repository
//!    folder names in practice, and unlike `canonical()`/`cleaned()` (ported via precomputed wire
//!    text per the `score.rs` boundary) this specific comparison has no existing Rust-side
//!    ASCII/Unicode split to reuse -- porting full ICU case folding here would require the same
//!    normalization crate slice-1 explicitly ruled out of scope. This is DELIBERATELY DIFFERENT
//!    from `canonical()`/`cleaned()`'s treatment: those stay wire-precomputed text (bit-identical
//!    by construction); THIS one is a real, believed-negligible-risk algorithmic divergence for
//!    non-ASCII root names, called out explicitly so it is not mistaken for an oversight.
//!
//! Every other string comparison in the ladder -- `canonical()` for index keys and
//! `findSingleComponentMatch`'s fuzzy compare, `cleaned(_).lowercased()` for the weighted-score
//! kernel and `findStrictSuffixMatch`'s suffix compare -- is Swift-precomputed onto the wire as
//! flat pooled text, exactly like `score.rs`'s existing fields, so Rust never re-implements
//! `cleaned()`/`canonical()`'s NFC-plus-alphanumeric-filter Unicode slow path.
//!
//! # Wire shape
//!
//! One request encodes a full immutable snapshot (roots/files/folders + candidate-bucket source
//! text) ONCE, plus a BATCH of queries sharing one `PathLocateOptions`-derived policy (matching
//! `PathMatchWorker.locateMany`'s single `profile` for the whole batch). Snapshot fields:
//!
//! - **Roots** (stride [`ROOT_STRIDE`]): `full_path_idx, name_idx` (both RAW, uncleaned pool
//!   text -- `full_path` for exact-path joins/`isUnder` checks, `name` for ASCII-fold alias
//!   matching against `resolve.rs`'s `last_path_component(full_path)` fallback).
//! - **Files** (stride [`FILE_STRIDE`]): `full_path_idx` (raw, exact lookup key),
//!   `relative_path_idx` (raw, returned to the caller and split for depth/tie-break math),
//!   `root_ordinal`, `name_canonical_idx` (`PathMatchIndexes.canonical(file.name, caseSensitive)`
//!   -- the `byFileName` index key AND `findSingleComponentMatch`'s fuzzy compare text),
//!   `ext_idx` (`(file.name as NSString).pathExtension.lowercased()`, possibly empty),
//!   `last_two_canonical_idx` (`canonical("\(comp[n-2])/\(comp[n-1])", caseSensitive)` when the
//!   relative path has >= 2 components, else an empty-string pool entry -- the `byLastTwo` index
//!   key), `component_start`/`component_count` into `component_indices` (each entry
//!   `cleaned(component).lowercased()` pooled text, forward order, filename last -- the
//!   `findStrictSuffixMatch`/weighted-score-kernel text, reusing `score.rs`'s `PooledComponent`
//!   convention verbatim so `resolve.rs` calls `weighted_component_score` unmodified).
//! - **Folders** (stride [`FOLDER_STRIDE`]): identical shape minus `ext`/`last_two` (Swift's
//!   `PathMatchIndexes.build` never indexes folders by extension or last-two-components).
//! - **Queries** (stride [`QUERY_STRIDE`]): `standardized_path_idx` plus two PARALLEL per-query
//!   component ranges -- `canonical_component_start`/`component_count` into
//!   `query_canonical_component_indices` (`canonical(rawComponent, caseSensitive)` per raw
//!   component of that query, forward order) and `cleaned_lower_component_start` (same count)
//!   into `query_cleaned_lower_component_indices` (`cleaned(rawComponent).lowercased()`,
//!   index-aligned 1:1 with the canonical array -- both derived from the SAME split of that
//!   query's `standardized_path`, which `resolve.rs` re-derives itself by splitting on `/` --
//!   pure, deterministic, no ICU involved in the split itself, so alignment holds by construction).

use super::contract::{
    FILE_STRIDE, FOLDER_STRIDE, PATH_RESOLVE_CONTRACT_VERSION_V1, QUERY_STRIDE, ROOT_STRIDE,
    STRING_RANGE_STRIDE,
};
use super::score::PooledComponent;
use std::collections::{HashMap, HashSet};
use std::fmt;

// ---- wire types -------------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PathMatchResolveRequestV1 {
    pub contract_version: u16,

    /// `PathMatchSnapshot.caseSensitive` -- a single policy flag for the whole snapshot.
    pub case_sensitive: bool,
    /// The single `PathLocateOptions` this batch shares (`PathMatchWorker.locateMany` takes one
    /// `profile` for the whole batch, not per-query).
    pub exact_match_only: bool,
    pub allow_leading_root_alias_trim: bool,
    pub allow_head_trim_aliases: bool,
    pub allow_absolute_suffix_fallback: bool,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub char_count_words: Vec<u64>,
    pub cleaned_byte_len_words: Vec<u64>,

    pub root_words: Vec<u64>,
    pub file_words: Vec<u64>,
    pub folder_words: Vec<u64>,
    /// Flat pool of pool-string indices sliced by each file/folder row's
    /// `(component_start, component_count)`. See the module doc.
    pub component_indices: Vec<u64>,

    /// Pool indices of `selectedFileFullPaths` (RAW full paths -- not necessarily a loaded file's
    /// own `full_path_idx`, since Swift's `rootsWithSelection` checks `isUnder` containment
    /// against arbitrary selected paths, not just ones that resolve to a known `FileRecord`).
    pub selected_file_full_path_indices: Vec<u64>,

    pub query_words: Vec<u64>,
    pub query_canonical_component_indices: Vec<u64>,
    pub query_cleaned_lower_component_indices: Vec<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PathMatchResolveError {
    InvalidRequest(String),
    Cancelled,
}

impl fmt::Display for PathMatchResolveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(value) => {
                write!(formatter, "invalid path-resolve request: {value}")
            }
            Self::Cancelled => formatter.write_str("path-resolve compute cancelled"),
        }
    }
}
impl std::error::Error for PathMatchResolveError {}

/// One query's outcome. Mirrors `PathMatchLocation?` -- `None` means "no match" (Swift `nil`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PathMatchResolveLocation {
    pub root_ordinal: u64,
    pub corrected_path: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PathMatchResolveResultV1 {
    /// Index-aligned with the request's queries. `None` for a query that found no match.
    pub locations: Vec<Option<PathMatchResolveLocation>>,
}

// ---- encode (request-builder helpers; used by Rust unit tests and mirrored by the Swift codec) -

impl PathMatchResolveRequestV1 {
    /// See `score.rs`'s `push_string` doc -- identical convention. `char_count`/`cleaned_byte_len`
    /// are only ever read for `component_indices` / `query_cleaned_lower_component_indices`
    /// entries; callers pushing non-scoring text (paths, canonical keys, extensions) may pass
    /// `text.chars().count() as u64` / `text.len() as u64` as harmless, never-read defaults.
    pub fn push_string(&mut self, text: &str, char_count: u64, cleaned_byte_len: u64) -> u64 {
        let start = self.utf8_blob.len() as u64;
        self.utf8_blob.extend_from_slice(text.as_bytes());
        let end = self.utf8_blob.len() as u64;
        let index = (self.string_range_words.len() / STRING_RANGE_STRIDE) as u64;
        self.string_range_words.push(start);
        self.string_range_words.push(end);
        self.char_count_words.push(char_count);
        self.cleaned_byte_len_words.push(cleaned_byte_len);
        index
    }

    /// Convenience for pool text that is never read as a `PooledComponent` (see `push_string`'s
    /// doc): self-derived `char_count`/`cleaned_byte_len`, never consulted.
    pub fn push_plain_string(&mut self, text: &str) -> u64 {
        self.push_string(text, text.chars().count() as u64, text.len() as u64)
    }

    pub fn push_root(&mut self, full_path: &str, name: &str) -> u64 {
        let ordinal = (self.root_words.len() / ROOT_STRIDE) as u64;
        let full_path_idx = self.push_plain_string(full_path);
        let name_idx = self.push_plain_string(name);
        self.root_words.extend([full_path_idx, name_idx]);
        ordinal
    }

    /// `components` are `(cleaned_lower_text, char_count, cleaned_byte_len)` triples -- see
    /// `score.rs`'s `push_string` doc for what those three values must be.
    #[allow(clippy::too_many_arguments)]
    pub fn push_file(
        &mut self,
        full_path: &str,
        relative_path: &str,
        root_ordinal: u64,
        name_canonical: &str,
        ext: &str,
        last_two_canonical: &str,
        components: &[(&str, u64, u64)],
    ) -> u64 {
        let ordinal = (self.file_words.len() / FILE_STRIDE) as u64;
        let full_path_idx = self.push_plain_string(full_path);
        let relative_path_idx = self.push_plain_string(relative_path);
        let name_canonical_idx = self.push_plain_string(name_canonical);
        let ext_idx = self.push_plain_string(ext);
        let last_two_canonical_idx = self.push_plain_string(last_two_canonical);
        let component_start = self.component_indices.len() as u64;
        for &(text, char_count, cleaned_byte_len) in components {
            let idx = self.push_string(text, char_count, cleaned_byte_len);
            self.component_indices.push(idx);
        }
        let component_count = self.component_indices.len() as u64 - component_start;
        self.file_words.extend([
            full_path_idx,
            relative_path_idx,
            root_ordinal,
            name_canonical_idx,
            ext_idx,
            last_two_canonical_idx,
            component_start,
            component_count,
        ]);
        ordinal
    }

    pub fn push_folder(
        &mut self,
        full_path: &str,
        relative_path: &str,
        root_ordinal: u64,
        name_canonical: &str,
        components: &[(&str, u64, u64)],
    ) -> u64 {
        let ordinal = (self.folder_words.len() / FOLDER_STRIDE) as u64;
        let full_path_idx = self.push_plain_string(full_path);
        let relative_path_idx = self.push_plain_string(relative_path);
        let name_canonical_idx = self.push_plain_string(name_canonical);
        let component_start = self.component_indices.len() as u64;
        for &(text, char_count, cleaned_byte_len) in components {
            let idx = self.push_string(text, char_count, cleaned_byte_len);
            self.component_indices.push(idx);
        }
        let component_count = self.component_indices.len() as u64 - component_start;
        self.folder_words.extend([
            full_path_idx,
            relative_path_idx,
            root_ordinal,
            name_canonical_idx,
            component_start,
            component_count,
        ]);
        ordinal
    }

    pub fn push_selected_file_full_path(&mut self, full_path: &str) {
        let idx = self.push_plain_string(full_path);
        self.selected_file_full_path_indices.push(idx);
    }

    /// `canonical_components`/`cleaned_lower_components` MUST be the same length (both derived
    /// from splitting the same `standardized_path` on `/`, one component-for-component pair per
    /// raw component -- see the module doc). `cleaned_lower_components` triples are
    /// `(text, char_count, cleaned_byte_len)`, same convention as `push_file`/`push_folder`.
    pub fn push_query(
        &mut self,
        standardized_path: &str,
        canonical_components: &[&str],
        cleaned_lower_components: &[(&str, u64, u64)],
    ) -> u64 {
        debug_assert_eq!(canonical_components.len(), cleaned_lower_components.len());
        let ordinal = (self.query_words.len() / QUERY_STRIDE) as u64;
        let standardized_path_idx = self.push_plain_string(standardized_path);
        let canonical_start = self.query_canonical_component_indices.len() as u64;
        for &text in canonical_components {
            let idx = self.push_plain_string(text);
            self.query_canonical_component_indices.push(idx);
        }
        let component_count = self.query_canonical_component_indices.len() as u64 - canonical_start;
        let cleaned_lower_start = self.query_cleaned_lower_component_indices.len() as u64;
        for &(text, char_count, cleaned_byte_len) in cleaned_lower_components {
            let idx = self.push_string(text, char_count, cleaned_byte_len);
            self.query_cleaned_lower_component_indices.push(idx);
        }
        self.query_words.extend([
            standardized_path_idx,
            canonical_start,
            component_count,
            cleaned_lower_start,
        ]);
        ordinal
    }
}

// ---- decode + fail-closed validation -----------------------------------------------------------

fn usize_word(value: u64) -> Result<usize, PathMatchResolveError> {
    usize::try_from(value).map_err(|_| {
        PathMatchResolveError::InvalidRequest("compact word exceeds platform index".into())
    })
}

fn validate_shape(request: &PathMatchResolveRequestV1) -> Result<(), PathMatchResolveError> {
    if request.string_range_words.len() % STRING_RANGE_STRIDE != 0 {
        return Err(PathMatchResolveError::InvalidRequest(
            "string_range_words length is not a multiple of STRING_RANGE_STRIDE".into(),
        ));
    }
    let pooled_count = request.string_range_words.len() / STRING_RANGE_STRIDE;
    if request.char_count_words.len() != pooled_count
        || request.cleaned_byte_len_words.len() != pooled_count
    {
        return Err(PathMatchResolveError::InvalidRequest(
            "char_count_words/cleaned_byte_len_words length does not match the pooled string count"
                .into(),
        ));
    }
    for (name, len, stride) in [
        ("root_words", request.root_words.len(), ROOT_STRIDE),
        ("file_words", request.file_words.len(), FILE_STRIDE),
        ("folder_words", request.folder_words.len(), FOLDER_STRIDE),
        ("query_words", request.query_words.len(), QUERY_STRIDE),
    ] {
        if len % stride != 0 {
            return Err(PathMatchResolveError::InvalidRequest(format!(
                "{name} length is not a multiple of its stride"
            )));
        }
    }
    Ok(())
}

fn decode_string(
    request: &PathMatchResolveRequestV1,
    index: u64,
) -> Result<PooledComponent<'_>, PathMatchResolveError> {
    let row = usize_word(index)?;
    let base = row.checked_mul(STRING_RANGE_STRIDE).ok_or_else(|| {
        PathMatchResolveError::InvalidRequest("string pool index overflow".into())
    })?;
    let range = request
        .string_range_words
        .get(base..base + STRING_RANGE_STRIDE)
        .ok_or_else(|| {
            PathMatchResolveError::InvalidRequest("string pool index out of range".into())
        })?;
    let start = usize_word(range[0])?;
    let end = usize_word(range[1])?;
    if end < start || end > request.utf8_blob.len() {
        return Err(PathMatchResolveError::InvalidRequest(
            "string range out of bounds".into(),
        ));
    }
    let text = std::str::from_utf8(&request.utf8_blob[start..end]).map_err(|_| {
        PathMatchResolveError::InvalidRequest("string range is not valid UTF-8".into())
    })?;
    let char_count = *request.char_count_words.get(row).ok_or_else(|| {
        PathMatchResolveError::InvalidRequest("char count pool index out of range".into())
    })?;
    let char_count = i64::try_from(char_count).map_err(|_| {
        PathMatchResolveError::InvalidRequest("char count exceeds platform index".into())
    })?;
    let cleaned_byte_len = *request.cleaned_byte_len_words.get(row).ok_or_else(|| {
        PathMatchResolveError::InvalidRequest("cleaned byte len pool index out of range".into())
    })?;
    let cleaned_byte_len = usize_word(cleaned_byte_len)?;
    Ok(PooledComponent::new(text, char_count, cleaned_byte_len))
}

fn decode_text(
    request: &PathMatchResolveRequestV1,
    index: u64,
) -> Result<&str, PathMatchResolveError> {
    decode_string(request, index).map(|pooled| pooled.text)
}

fn decode_components<'a>(
    request: &'a PathMatchResolveRequestV1,
    pool: &[u64],
    start: u64,
    count: u64,
) -> Result<Vec<PooledComponent<'a>>, PathMatchResolveError> {
    let start = usize_word(start)?;
    let count = usize_word(count)?;
    let end = start
        .checked_add(count)
        .ok_or_else(|| PathMatchResolveError::InvalidRequest("component range overflow".into()))?;
    let indices = pool.get(start..end).ok_or_else(|| {
        PathMatchResolveError::InvalidRequest("component range out of bounds".into())
    })?;
    indices
        .iter()
        .map(|&index| decode_string(request, index))
        .collect()
}

pub(crate) struct DecodedRoot<'a> {
    pub full_path: &'a str,
    pub name: &'a str,
}

pub(crate) struct DecodedFile<'a> {
    pub full_path: &'a str,
    pub relative_path: &'a str,
    pub root_ordinal: usize,
    pub name_canonical: &'a str,
    pub ext: &'a str,
    pub last_two_canonical: &'a str,
    pub components: Vec<PooledComponent<'a>>,
}

pub(crate) struct DecodedFolder<'a> {
    pub full_path: &'a str,
    pub relative_path: &'a str,
    pub root_ordinal: usize,
    pub name_canonical: &'a str,
    pub components: Vec<PooledComponent<'a>>,
}

pub(crate) struct DecodedQuery<'a> {
    pub standardized_path: &'a str,
    /// Raw components' `canonical()` form, forward order (index-aligned with
    /// `cleaned_lower_components`).
    pub canonical_components: Vec<&'a str>,
    /// Raw components' `cleaned().lowercased()` form, forward order.
    pub cleaned_lower_components: Vec<PooledComponent<'a>>,
}

/// Fully decoded snapshot + candidate-bucket indexes, built once per `locateMany` batch.
/// Everything downstream (`resolve.rs`) borrows from this rather than re-decoding per query.
pub(crate) struct DecodedSnapshot<'a> {
    pub case_sensitive: bool,
    pub exact_match_only: bool,
    pub allow_leading_root_alias_trim: bool,
    pub allow_head_trim_aliases: bool,
    pub allow_absolute_suffix_fallback: bool,

    pub roots: Vec<DecodedRoot<'a>>,
    pub files: Vec<DecodedFile<'a>>,
    pub folders: Vec<DecodedFolder<'a>>,
    pub queries: Vec<DecodedQuery<'a>>,

    /// Raw `selectedFileFullPaths` text (not necessarily a known file's own `full_path`).
    pub selected_file_full_paths: HashSet<&'a str>,

    /// `PathMatchIndexes.byFileName`: file ordinals keyed by `name_canonical`.
    pub by_file_name: HashMap<&'a str, Vec<usize>>,
    /// `PathMatchIndexes.byLastTwo`: file ordinals keyed by `last_two_canonical` (files with < 2
    /// components never contribute a key here, matching Swift).
    pub by_last_two: HashMap<&'a str, Vec<usize>>,
    /// `PathMatchIndexes.byExtension`: file ordinals keyed by `ext` (files with an empty `ext`
    /// never contribute a key here, matching Swift's `if !ext.isEmpty`).
    pub by_extension: HashMap<&'a str, Vec<usize>>,
    /// `PathMatchIndexes.foldersByLastComponent`: folder ordinals keyed by `name_canonical`.
    pub folders_by_last_component: HashMap<&'a str, Vec<usize>>,

    /// ASCII-fold-lowercased root ordinal groups keyed by `root.name` -- see the module doc's
    /// boundary note 3. Built once; reused by both `alias_root_candidates` and
    /// `build_head_trim_variants`.
    pub root_alias_by_name_lower: HashMap<String, Vec<usize>>,
    /// Same, keyed by `last_path_component(root.full_path)`.
    pub root_alias_by_last_component_lower: HashMap<String, Vec<usize>>,
}

fn ascii_lower_owned(s: &str) -> String {
    // ASCII-only fold (see the module doc's boundary note 3): non-ASCII scalars pass through
    // unchanged rather than attempting full ICU case folding. Iterates `chars()`, NOT `bytes()`,
    // so multi-byte UTF-8 sequences are never split.
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

pub(crate) fn decode(
    request: &PathMatchResolveRequestV1,
) -> Result<DecodedSnapshot<'_>, PathMatchResolveError> {
    if request.contract_version != PATH_RESOLVE_CONTRACT_VERSION_V1 {
        return Err(PathMatchResolveError::InvalidRequest(format!(
            "unknown contract version {}",
            request.contract_version
        )));
    }
    validate_shape(request)?;

    let mut roots = Vec::with_capacity(request.root_words.len() / ROOT_STRIDE);
    for row in request.root_words.chunks_exact(ROOT_STRIDE) {
        roots.push(DecodedRoot {
            full_path: decode_text(request, row[0])?,
            name: decode_text(request, row[1])?,
        });
    }

    let mut by_file_name: HashMap<&str, Vec<usize>> = HashMap::new();
    let mut by_last_two: HashMap<&str, Vec<usize>> = HashMap::new();
    let mut by_extension: HashMap<&str, Vec<usize>> = HashMap::new();
    let mut files = Vec::with_capacity(request.file_words.len() / FILE_STRIDE);
    for row in request.file_words.chunks_exact(FILE_STRIDE) {
        let root_ordinal = usize_word(row[2])?;
        if root_ordinal >= roots.len() {
            return Err(PathMatchResolveError::InvalidRequest(
                "file root_ordinal out of range".into(),
            ));
        }
        let file = DecodedFile {
            full_path: decode_text(request, row[0])?,
            relative_path: decode_text(request, row[1])?,
            root_ordinal,
            name_canonical: decode_text(request, row[3])?,
            ext: decode_text(request, row[4])?,
            last_two_canonical: decode_text(request, row[5])?,
            components: decode_components(request, &request.component_indices, row[6], row[7])?,
        };
        let ordinal = files.len();
        by_file_name
            .entry(file.name_canonical)
            .or_default()
            .push(ordinal);
        if !file.last_two_canonical.is_empty() {
            by_last_two
                .entry(file.last_two_canonical)
                .or_default()
                .push(ordinal);
        }
        if !file.ext.is_empty() {
            by_extension.entry(file.ext).or_default().push(ordinal);
        }
        files.push(file);
    }

    let mut folders_by_last_component: HashMap<&str, Vec<usize>> = HashMap::new();
    let mut folders = Vec::with_capacity(request.folder_words.len() / FOLDER_STRIDE);
    for row in request.folder_words.chunks_exact(FOLDER_STRIDE) {
        let root_ordinal = usize_word(row[2])?;
        if root_ordinal >= roots.len() {
            return Err(PathMatchResolveError::InvalidRequest(
                "folder root_ordinal out of range".into(),
            ));
        }
        let folder = DecodedFolder {
            full_path: decode_text(request, row[0])?,
            relative_path: decode_text(request, row[1])?,
            root_ordinal,
            name_canonical: decode_text(request, row[3])?,
            components: decode_components(request, &request.component_indices, row[4], row[5])?,
        };
        let ordinal = folders.len();
        folders_by_last_component
            .entry(folder.name_canonical)
            .or_default()
            .push(ordinal);
        folders.push(folder);
    }

    let mut root_alias_by_name_lower: HashMap<String, Vec<usize>> = HashMap::new();
    let mut root_alias_by_last_component_lower: HashMap<String, Vec<usize>> = HashMap::new();
    for (ordinal, root) in roots.iter().enumerate() {
        root_alias_by_name_lower
            .entry(ascii_lower_owned(root.name))
            .or_default()
            .push(ordinal);
        let last = super::resolve::last_path_component(root.full_path);
        root_alias_by_last_component_lower
            .entry(ascii_lower_owned(last))
            .or_default()
            .push(ordinal);
    }

    let mut selected_file_full_paths =
        HashSet::with_capacity(request.selected_file_full_path_indices.len());
    for &idx in &request.selected_file_full_path_indices {
        selected_file_full_paths.insert(decode_text(request, idx)?);
    }

    let mut queries = Vec::with_capacity(request.query_words.len() / QUERY_STRIDE);
    for row in request.query_words.chunks_exact(QUERY_STRIDE) {
        let standardized_path = decode_text(request, row[0])?;
        let canonical_start = usize_word(row[1])?;
        let component_count = usize_word(row[2])?;
        let canonical_end = canonical_start
            .checked_add(component_count)
            .ok_or_else(|| {
                PathMatchResolveError::InvalidRequest("query component range overflow".into())
            })?;
        let canonical_indices = request
            .query_canonical_component_indices
            .get(canonical_start..canonical_end)
            .ok_or_else(|| {
                PathMatchResolveError::InvalidRequest(
                    "query canonical component range out of bounds".into(),
                )
            })?;
        let canonical_components = canonical_indices
            .iter()
            .map(|&idx| decode_text(request, idx))
            .collect::<Result<Vec<_>, _>>()?;
        let cleaned_lower_components = decode_components(
            request,
            &request.query_cleaned_lower_component_indices,
            row[3],
            row[2],
        )?;
        if canonical_components.len() != cleaned_lower_components.len() {
            return Err(PathMatchResolveError::InvalidRequest(
                "query canonical/cleaned-lower component counts differ".into(),
            ));
        }
        queries.push(DecodedQuery {
            standardized_path,
            canonical_components,
            cleaned_lower_components,
        });
    }

    Ok(DecodedSnapshot {
        case_sensitive: request.case_sensitive,
        exact_match_only: request.exact_match_only,
        allow_leading_root_alias_trim: request.allow_leading_root_alias_trim,
        allow_head_trim_aliases: request.allow_head_trim_aliases,
        allow_absolute_suffix_fallback: request.allow_absolute_suffix_fallback,
        roots,
        files,
        folders,
        queries,
        selected_file_full_paths,
        by_file_name,
        by_last_two,
        by_extension,
        folders_by_last_component,
        root_alias_by_name_lower,
        root_alias_by_last_component_lower,
    })
}
