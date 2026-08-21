#![no_main]

use std::sync::OnceLock;

use agentry_runtime::{
    LeafCancellation, PathClause, PathFilterRequest, PathSnapshot, RuntimeIdentity, SearchLeaf,
};
use libfuzzer_sys::fuzz_target;

const MAX_SNAPSHOTS: usize = 32;
const MAX_CLAUSES: usize = 16;
const MAX_STRING_BYTES: usize = 256;

struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn byte(&mut self) -> u8 {
        let value = self.bytes.get(self.offset).copied().unwrap_or(0);
        self.offset = self.offset.saturating_add(1);
        value
    }

    fn text(&mut self) -> String {
        let length = usize::from(self.byte()).min(MAX_STRING_BYTES);
        let start = self.offset.min(self.bytes.len());
        let end = start.saturating_add(length).min(self.bytes.len());
        let value = String::from_utf8_lossy(&self.bytes[start..end]).into_owned();
        self.offset = end;
        value
    }
}

fn cancellation() -> LeafCancellation {
    let identity = RuntimeIdentity::new(1, "4".repeat(32), "5".repeat(64), "6".repeat(64))
        .expect("static fuzz identity must be valid");
    LeafCancellation::new(identity)
}

fuzz_target!(|input: &[u8]| {
    let mut cursor = Cursor {
        bytes: input,
        offset: 0,
    };
    let options = cursor.byte();
    let snapshot_count = usize::from(cursor.byte()) % (MAX_SNAPSHOTS + 1);
    let clause_count = usize::from(cursor.byte()) % (MAX_CLAUSES + 1);

    let snapshots = (0..snapshot_count)
        .map(|_| PathSnapshot {
            standardized_full_path: cursor.text(),
            standardized_relative_path: cursor.text(),
            standardized_root_path: cursor.text(),
            client_display_path: cursor.text(),
        })
        .collect();
    let clauses = (0..clause_count)
        .map(|_| {
            let kind = cursor.byte() % 4;
            let first = cursor.text();
            let second = cursor.text();
            let root = (cursor.byte() & 1 != 0).then(|| cursor.text());
            match kind {
                0 => PathClause::ExactFile {
                    abs_path: first,
                    rel_path: second,
                    restricted_root_path: root,
                },
                1 => PathClause::ExactFolder {
                    abs_lower: first,
                    rel_lower: second,
                    restricted_root_path: root,
                },
                2 => PathClause::Glob {
                    pattern: first,
                    restricted_root_path: root,
                },
                _ => PathClause::LegacyPrefix {
                    candidate_lower: first,
                },
            }
        })
        .collect();

    static LEAF: OnceLock<Option<SearchLeaf>> = OnceLock::new();
    let Some(leaf) = LEAF.get_or_init(|| SearchLeaf::new().ok()) else {
        return;
    };
    let _ = leaf.filter_paths(&PathFilterRequest {
        snapshots,
        clauses,
        case_insensitive: options & 1 != 0,
        cancellation: cancellation(),
    });
});
