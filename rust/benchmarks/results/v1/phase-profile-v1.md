# Rust search phase profile v1

- Artifact is instrumented/profile-only and is not eligible for the formal SLO report.
- All representative variants used PCRE2 with active JIT; production and forced-PCRE2 were equivalent.
- Hits-path CPU attribution coverage is 94.1%-99.98%; retained live-block attribution is 99.3%-99.8% (allocation-event traces remain a stated limitation).
- Three-process count-only reproducibility passes ±5% for large/density; batch spread is 5.84%, so the strict reproducibility gate remains open.
- Before O1a production built both Rust `LineTable` and Swift `SearchLineIndex`; after O1a only Rust builds the production line table.
- `pcre2` match data is pooled per compiled regex/find operation and reused across matches; it is not allocated per match.
- Legacy C case-sensitive whole-word/marker scans use `memchr`; other paths are contiguous byte loops without a line object graph.

## Paired CPU p50

| Fixture | Batch | Count-only | Hits | Hits+context | Hit-payload share |
|---|---:|---:|---:|---:|---:|
| representative-large-subject | 1 | 0.086 ms | 136.968 ms | 460.153 ms | 99.94% |
| representative-multi-file-batch | 64 | 0.228 ms | 3.866 ms | 11.034 ms | 94.10% |
| representative-match-density | 1 | 0.056 ms | 271.367 ms | 828.955 ms | 99.98% |

## H1-H7

- **H1**: confirmed: Bridge UTF-8 range validation is already dominant for hits; pre-O1a production additionally rebuilt SearchLineIndex
- **H2**: confirmed: nested per-hit/context DTO and lift/validation pipeline explains 94.1%-99.98% of hits-path CPU
- **H3**: confirmed before O1a: Rust LineTable and Swift SearchLineIndex were both built; O1a removes the Swift production build
- **H4**: confirmed before O4 and fixed: FFI batch looped the complete single-request entry; prepared pattern/cache lookup is now once per batch
- **H5**: not exercised by representative fixtures: all three production variants report pcre2
- **H6**: refuted as per-match allocation: pcre2 crate pools match data and one find_iter guard spans all matches
- **H7**: refuted as primary cause: forced-PCRE2 is equivalent and count-only PCRE2 cost is 0.057-0.228 ms
