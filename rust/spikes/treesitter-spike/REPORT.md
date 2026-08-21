# Tree-sitter dependency spike report

Date: 2026-08-21
Scope: isolated P2-1 dependency validation only; this crate is not a member of the parent `rust/` workspace.

## Decision

The 13 planned language entries compile and run against one exact runtime:

```toml
tree-sitter = "=0.25.10"
```

The grammar repositories remain pinned to the P2 plan's exact revisions. The spike owns its `Cargo.toml` and `Cargo.lock`, declares an empty `[workspace]` to prevent parent-workspace membership, and was built only with:

```text
CARGO_TARGET_DIR=/tmp/agentry-treesitter-spike-target
```

P2-2 can copy the dependency pins from this crate into the main workspace when its owner is ready. No thin compatibility adapter was required.

## Grammar inventory

All Cargo metadata licenses resolved to MIT. Scanner shape is the generated source actually present at the pinned checkout; `none` means parser-only C with no external scanner source.

| Language | Cargo package/version | Exact revision | License | External scanner source |
|---|---|---|---|---|
| Swift | `tree-sitter-swift 0.7.0` | `31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5` | MIT | C: `src/scanner.c` |
| JavaScript | `tree-sitter-javascript 0.25.0` | `44c892e0be055ac465d5eeddae6d3e194424e7de` | MIT | C: `src/scanner.c` |
| C# | `tree-sitter-c-sharp 0.23.5` | `cac6d5fb595f5811a076336682d5d595ac1c9e85` | MIT | C: `src/scanner.c` |
| Python | `tree-sitter-python 0.25.0` | `293fdc02038ee2bf0e2e206711b69c90ac0d413f` | MIT | C: `src/scanner.c` |
| C | `tree-sitter-c 0.24.2` | `b780e47fc780ddc8da13afa35a3f4ed5c157823d` | MIT | none |
| Rust | `tree-sitter-rust 0.24.2` | `77a3747266f4d621d0757825e6b11edcbf991ca5` | MIT | C: `src/scanner.c` |
| C++ | `tree-sitter-cpp 0.23.4` | `f41e1a044c8a84ea9fa8577fdd2eab92ec96de02` | MIT | C: `src/scanner.c` |
| Go | `tree-sitter-go 0.25.0` | `1547678a9da59885853f5f5cc8a99cc203fa2e2c` | MIT | none |
| Java | `tree-sitter-java 0.23.5` | `94703d5a6bed02b98e438d7cad1136c01a60ba2c` | MIT | none |
| TypeScript | `tree-sitter-typescript 0.23.2` | `f975a621f4e7f532fe322e13c4f79495e0a7b2e7` | MIT | C: `typescript/src/scanner.c` |
| TSX | `tree-sitter-typescript 0.23.2` | `f975a621f4e7f532fe322e13c4f79495e0a7b2e7` | MIT | C: `tsx/src/scanner.c` |
| PHP | `tree-sitter-php 0.24.2` | `5b5627faaa290d89eb3d01b9bf47c3bb9e797dea` | MIT | C: `php/src/scanner.c` (`php_only/src/scanner.c` is also built by the crate) |
| Ruby | `tree-sitter-ruby 0.23.1` | `71bd32fb7607035768799732addba884a37a6210` | MIT | C: `src/scanner.c` |

Transitive tree-sitter support packages observed: `tree-sitter-language 0.1.7` (MIT) and the single runtime `tree-sitter 0.25.10` (MIT).

## Parse and query smoke

`src/lib.rs` parses a real, syntactically valid small sample for each of the 13 language entries and runs a compiled wildcard tree-sitter query (`(_) @node`) against the resulting tree. Each parse must have no error node and each query must return more than one match. TypeScript and TSX use their distinct language entry points and samples. The Python test was first proven independently before adding the remaining grammars.

Final command:

```bash
CARGO_TARGET_DIR=/tmp/agentry-treesitter-spike-target \
  cargo test \
  --manifest-path rust/spikes/treesitter-spike/Cargo.toml \
  --locked --offline
```

Result: `1 passed; 0 failed`; the single table-style test executed and asserted all 13 language parse/query cases.

## Dependency convergence evidence

```bash
CARGO_TARGET_DIR=/tmp/agentry-treesitter-spike-target \
  cargo tree --manifest-path rust/spikes/treesitter-spike/Cargo.toml \
  --locked --offline -d
```

Result: `nothing to print` (no duplicate packages/versions in the selected graph).

```bash
cargo tree ... -i tree-sitter@0.25.10
```

Result: `tree-sitter v0.25.10` has one direct consumer, this spike crate. Grammar bindings use the common `tree-sitter-language` ABI descriptor and introduce no second runtime.

## Arm64 static archive evidence

Required build:

```bash
CARGO_TARGET_DIR=/tmp/agentry-treesitter-spike-target \
  cargo build --release --target aarch64-apple-darwin \
  --manifest-path rust/spikes/treesitter-spike/Cargo.toml --locked
```

Result: success. Artifact:

```text
/tmp/agentry-treesitter-spike-target/aarch64-apple-darwin/release/libagentry_treesitter_spike.a
```

Evidence:

- `file`: current ar archive.
- `lipo -info`: non-fat architecture `arm64`.
- Archive contains 449 object members.
- A release-visible probe references all language entry points; `nm -g` found exactly 13 grammar entry symbols.
- `nm -g` found external-scanner symbol families for C#, C++, JavaScript, PHP/PHP-only, Python, Ruby, Rust, Swift, TypeScript, and TSX, proving their scanner C objects are present in the release archive.
- `otool -L` enumerated archive object members without a dylib dependency line.
- `otool -l | grep LC_LOAD_DYLIB` count: `0`. The archive adds no dynamic tree-sitter, grammar, scanner, or system-library load command.

A final app/archive integration gate must repeat `otool` on `libagentry_ffi.a` and the packaged product after P2-2 wiring; this spike proves the isolated static supply chain only.

## Files produced

- `Cargo.toml`: isolated exact dependency manifest.
- `Cargo.lock`: isolated reproducible lock.
- `src/lib.rs`: generic parse/query helper, 13-language smoke, and release linkage probe.
- `REPORT.md`: this evidence and supply-chain inventory.

No target directory is stored in the repository.

## Items intentionally deferred for registration

The parallel owner of `Scripts/` and the main Rust workspace must handle these later; this spike did not modify those owned paths:

1. Add the two new architecture documents to any explicit source-layout documentation allowlist:
   - `docs/architecture/rust-codemap-compact-v1.md`
   - `docs/architecture/rust-apply-edits-compact-v1.md`
2. Replace the SwiftPM grammar/scanner guardrails with the exact Cargo pins, single-runtime check, lock check, and static scanner/archive check during the atomic P2 supply-chain cut.
3. Add/update `ThirdPartyLicenses/tree-sitter/**` snapshots from these 12 pinned grammar repositories plus runtime/support packages.
4. Copy pins into `rust/Cargo.toml`, reference them from `rust/crates/runtime/Cargo.toml`, and update the main `rust/Cargo.lock` only in P2-2.

## Maintainer-guidance check

- **User impact and invariant:** preserve all 13 CodeMap languages while eliminating an unverified Rust dependency risk; one runtime and static scanner supply must hold.
- **Root-cause confidence:** confirmed dependency compatibility and static archive evidence for the isolated crate; production integration remains untested by design.
- **Authority:** exact P2 grammar revisions and the isolated Cargo lock/metadata.
- **State-safety risks:** none; no workspace/path/persistence or app state is touched.
- **Scale and observability risks:** compile/link cost exists but no runtime benchmark was claimed by this dependency spike.
- **Recommended scope:** proceed to P2-2 using these pins; keep final archive/app inspection as a later integration gate.
- **Validation boundary:** isolated Cargo tests, dependency tree, arm64 archive, symbols, and Mach-O load commands.
