# agent-claude-derisking-spike

P6-2 de-risking spike for the Claude vertical
(`docs/designs/p6-claude-vertical-2026-08-23.md` section 8,
`docs/architecture/rust-agent-claude-v1.md`). Produces GO/NO-GO evidence for E-P6-1(c), E-P6-2
(Part A/Part B/R2b), and E-P6-3. **Not the P6-3/P6-4 production port** -- see `src/lib.rs`'s module
doc and each module's own doc comment for exactly what is and is not a faithful port versus a
scoped-down harness.

Results are written up in `rust/benchmarks/results/v1/p6-2-claude-derisking-v1.md` (primary) and
`.json` (raw data), and referenced from `rust/benchmarks/slo-v1.json`'s `p6TwoResults`/
`agentClaudeV1` keys. Read the results doc before this README if you want the verdicts; this file
is a map of what lives where.

Isolated from the parent `rust/` workspace (own `[workspace]` table, own `Cargo.lock`), matching
the `inventory-scope-spike`/`treesitter-spike` precedent -- not a member of `rust/Cargo.toml`, not
touched by `make dev-cargo-*`, `cargo run -p xtask -- generate`, or codegen/identity regeneration.

## Layout

- `src/tool_owned.rs` -- E-P6-1(c): host-owned-tool-name predicate, ported as pure data (contract
  section 8).
- `src/spawn.rs` -- E-P6-2 Part A: `posix_spawnp` mirror of `ProcessLauncher.swift` via `nix`,
  zero `unsafe`, `chdir` intentionally unimplemented (see module doc).
- `src/reaper.rs` -- E-P6-2 Part B/R2b: shared-kqueue reaper mirroring `ChildStatusReaperRegistry`
  (contract section 5.2). Contains the one confirmed-necessary `unsafe` block in this crate
  (`waitid_probe`, wrapping `libc::waitid`, which `nix` does not expose on Apple targets).
- `src/stream.rs` -- E-P6-3: an INV-P6-2 reader harness (unconditional draining, non-blocking
  bounded-queue publish). Transport-plane only, no JSON codec -- see module doc for the exact
  scope boundary.
- `bin/probe.rs` -- E-P6-2 Part A's shared attribute-report child, launched by both this crate's
  spawner and the Swift-side `ProcessLauncher.spawn` arm
  (`Tests/RepoPromptTests/AgentMode/ClaudeCompatible/SpawnAttributeParityTests.swift`). `#![no_main]`
  deliberately -- see its module doc for why a normal `fn main()` Rust binary would have silently
  contaminated the `SIGPIPE`-disposition measurement.
- `bin/synthetic_cli.rs` -- E-P6-3's synthetic CLI stand-in (`flood`, `oversized-line`,
  `mid-line-stall`, `stdin-starved-flood` modes).
- `fixtures/host-owned-tool-name-cases-v1.json` -- the 53-case curated fixture both the Rust arm
  (`src/tool_owned.rs`'s `#[cfg(test)]` module) and the Swift arm
  (`HostOwnedToolNamePredicateDifferentialTests.swift`) assert against.
- `tests/spawn_and_reaper.rs` -- E-P6-2 Part A (9 configurations) + Part B (reduced-scale
  coexistence soak) + R2b (thread-scaling with synthetic reader threads).
- `tests/adversarial_stream.rs` -- E-P6-3 (oversized-line, mid-line-stall, flood, the named
  deadlock probe).
- `tests/combined_session_scaling.rs` -- R2b/open-question-1's strongest evidence: real
  spawn+reader+reaper sessions at N=1/4/16, not simulated threads.

## Reproducing

```bash
cd rust/spikes/agent-claude-derisking-spike
cargo test                                    # everything on stable toolchain
cargo build --bin probe                       # needed before the Swift arm (SpawnAttributeParityTests)
RUSTFLAGS="-Z sanitizer=thread" cargo +nightly test --target aarch64-apple-darwin -Zbuild-std --test spawn_and_reaper -- --test-threads=1
RUSTFLAGS="-Z sanitizer=address" cargo +nightly test --target aarch64-apple-darwin -Zbuild-std --test spawn_and_reaper -- --test-threads=1
```

From the repo root, the Swift arms run via the coordinated daemon:

```bash
make dev-test FILTER=HostOwnedToolNamePredicateDifferentialTests
make dev-test FILTER=SpawnAttributeParityTests
```
