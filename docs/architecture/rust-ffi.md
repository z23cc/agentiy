# Rust FFI Phase 0 Contracts and Foundation

**Status:** Phase 0 Rust contract, runtime, UniFFI, deterministic artifacts, coordinated build authority, and Swift bridge graph (Phases 1–8)
**ABI epoch:** 1
**Envelope schema:** 1
**Supported Rust target:** `aarch64-apple-darwin` only
**Minimum macOS deployment target:** 14.0

This document freezes the acceptance gates, boundary contracts, fixture policy, and dependency ownership for the Agentry Rust FFI skeleton. It does not yet accept UniFFI for product use, migrate a product domain, connect `RepoPromptApp`, or create a second runtime authority. The strategic source is `docs/architecture/agentry-rewrite-charter.md` (tracked snapshot of `docs/designs/rust-core-swiftui-shell-rewrite-2026-08-20.md`, which remains the living, gitignored working copy); the machine-readable contract is `rust/ffi-contract/abi-v1.json`.

## Scope and non-goals

Phases 1–6 establish:

- an auditable G1–G8 acceptance matrix;
- ABI epoch 1, envelope v1, operation, identity, error, and SLO contracts;
- deterministic synthetic fixtures and a format for later redacted Swift baselines;
- a virtual Cargo workspace with product crates `agentry-proto`, `agentry-runtime`, and `agentry-ffi`, plus the repository-only `xtask` tool;
- an exact Rust toolchain, arm64-only target, lockfile, unwind profiles, and dependency/security policy;
- fast source guardrails that require no network or Cargo build.
- the fail-closed envelope v1 codec and bounded decoder helpers;
- the typed operation registry, cancellation tombstones, deadline conversion, first-terminal-wins diagnostics, and owned Tokio runtime lifecycle;
- bounded subscription queues, atomic bootstrap, finite drain/oversize results, and a nonblocking wake pipe with lock-scoped rearm-and-recheck;
- proc-macro-only synchronous UniFFI exports with typed records/errors, RuntimeIdentity validation, project-owned panic poison, idempotent close/shutdown, and controlled wake-FD duplication;
- deterministic arm64 staticlib construction, Swift/header/ordinary-modulemap generation, canonical CoreBuildFingerprint injection, checked-in artifact hashes, and zero-diff regeneration.

The remaining Phase 0 closure items are the redacted current-Swift representative-payload baseline and SLO comparison and separately registered release dead-strip/dSYM symbolication evidence. The ADR decision is recorded: `docs/architecture/adr-0001-uniffi-raw-binder.md` is **Accepted** (user decision, 2026-08-20). `RepoPromptApp` still has no dependency on the raw or bridge targets.

## Acceptance gate matrix

| Gate | Frozen decision | Final evidence owner | Current Phase 0 evidence |
|---|---|---|---|
| **G1 Contract** | ABI epoch, typed control inventory, envelope, limits, errors, fixture formats, and SLO caps are versioned | contract tests, goldens, SLO verifier | `abi-v1.json`, `exports.txt`, fixtures, `slo-v1.json`, `proto/tests/envelope_v1.rs` |
| **G2 Rust Foundation** | one virtual workspace, exact toolchain/target/lock, unwind profiles, one product UniFFI owner | metadata, build/test, deny/audit | manifests, lockfile, toolchain/config, policy guardrail, 43 locked workspace tests, and conductor `cargo-deny`/`cargo-audit` operations; fail-closed CI execution is tracked under G8 |
| **G3 Runtime Lifecycle** | owned runtime, operation registry, deadlines, tombstones, first-terminal-wins, bounded shutdown | lifecycle and randomized tests | `operation_registry.rs`, `runtime_lifecycle.rs`, `randomized_lifecycle.rs`, and `shutdown_races.rs`; focused Swift operation/initialization/shutdown tests cover the bridge half |
| **G4 Subscription/Wake** | bounded count/bytes, terminal/control reserve, oversize policy, drain and lossless wake/rearm | queue/FD/race tests | `subscription_backpressure.rs`, `wake_pipe.rs`, and `shutdown_races.rs`; focused Swift DispatchSource and ThreadSanitizer evidence passes; representative real-payload measurement remains open |
| **G5 FFI Safety/Identity** | synchronous typed `Result`, panic poison, ABI/checksum/fingerprint and stale identity rejection | FFI integration tests | `ffi/src/{api,types,errors,panic_guard}.rs`; locked workspace tests cover panic poison, idempotent close/shutdown, and fingerprint mismatch rejection |
| **G6 Reproducible Artifacts** | deterministic codegen/archive/identity, arm64-only symbols | xtask zero-diff and artifact verification | `dev-cargo-codegen-check`, profile-specific manifests, and conductor-selected `.build/agentry-rust/current` archive verified by SHA-256 before Swift builds |
| **G7 Swift/Link/Xcode** | private C/raw/bridge layering, Swift 6, debug/release link and symbolication | dedicated bridge/link/Xcode tests | `CAgentryRustCore → AgentryUniFFIRaw → AgentryCoreBridge → AgentryCoreBridgeTests`; raw/bridge/tests compile with Swift 6 strict concurrency and warnings-as-errors; focused debug, release, and ThreadSanitizer bridge tests pass; `xcode-rust-link-validate` owns non-launching build-for-testing; dead-strip/dSYM symbolication registered 2026-08-21 (see G7 symbolication register below) |
| **G8 Governance** | conductor-only heavy entry, CI, guardrails, preflight and dependency/license policy | **Pass** — pinned cargo-deny 0.20.2 / cargo-audit 0.22.2 / cargo-fuzz 0.12.0 installed fail-closed in CI (`ci.yml:170-175`, `--locked` + version assertion); `cargo deny check` + `cargo audit` mandatory and unconditional (`ci.yml:191,195`); **nine** bounded 60s fuzz jobs — one per declared `rust/fuzz` target, kept in lockstep by `Scripts/rust_ffi_guardrails.py::check_fuzz_target_coverage`; pr-ready Rust path selection in contribution preflight (`preflight.sh:229,269,332-351`). **Execution model (2026-09-01):** this job is `workflow_dispatch` **only** — no cron. The earlier weekly schedule was registered while every heavy job still failed within ~3 minutes, so its measured cost was meaningless; the true post-fix per-run cost is unmeasured and must be read from one dispatch run before any cadence is committed. Pull requests run the secret scan alone. The per-change gate is local `preflight.sh pr-ready`, which selects `dev-cargo-{test,codegen-check,deny,audit}` on Rust-path changes. Advisory coverage — the one check that degrades with time rather than with changes — is split into the weekly Linux `dependency-audit` job at 1x billing. Fuzz and the bridge TSan matrix run on dispatch | first-class Cargo operations claim `build` + heavy admission; Make aliases and archive-before-Swift verification are active; `.github/workflows/ci.yml` fail-closes dependency policy and runs bounded fuzz plus debug/release/ThreadSanitizer bridge coverage; Rust, generated-binding, and bridge paths select the Rust PR-ready validation set |

### G1–G8 final status summary

The project gate IDs below remain the stable primary keys. The “Charter §15.2 item” column explicitly maps them to the eight technical acceptance items preserved by the Phase 0 plan: (1) binding/contract compatibility, (2) admission/cancel, (3) queue/wake/lifecycle, (4) representative payload benchmark, (5) debug/release/race bridge validation, (6) deterministic generation and architecture, (7) Swift strict-concurrency enforcement, and (8) decoder fuzz/security.

| Project gate | Charter §15.2 item | Conclusion | Evidence pointer | Gap / condition |
|---|---|---|---|---|
| **G1 Contract** | 1 binding/contract; 8 decoder bounds | **Pass** | `rust/ffi-contract/{abi-v1.json,exports.txt,generated-manifest.json}`; `rust/crates/proto/tests/envelope_v1.rs`; `make dev-cargo-test CARGO_PACKAGE=all` | The contract, limits, fixtures, and SLO caps are frozen. Real-payload measurement is assessed under G4 rather than used to rewrite the contract. |
| **G2 Rust Foundation** | 1 binding/toolchain; 6 architecture | **Pass** | `rust/{Cargo.toml,Cargo.lock,rust-toolchain.toml,.cargo/config.toml,deny.toml,audit.toml}`; `Scripts/rust_ffi_guardrails.py`; 43 Rust tests via `make dev-cargo-test CARGO_PACKAGE=all` | CI dependency-policy enforcement is a governance closure item under G8; it does not change the verified single-owner, exact-pin, lockfile, unwind, and arm64 foundation. |
| **G3 Runtime Lifecycle** | 2 admission/cancel; 3 lifecycle | **Pass** | `operation_registry.rs`; `randomized_lifecycle.rs::admission_cancel_randomized_soak_has_no_operation_or_task_leaks` (12,000 schedules, zero active operation/task leakage); `runtime_lifecycle.rs`; `shutdown_races.rs` | No runtime-lifecycle evidence gap remains for the P0 skeleton. Product-domain integration is out of scope. |
| **G4 Subscription/Wake** | 3 queue/wake/lifecycle; 4 representative payload benchmark | **Pass** | `subscription_backpressure.rs`; `wake_pipe.rs`; `shutdown_races.rs`; focused ThreadSanitizer `AgentryCoreBridgeTests`; representative real-payload floors in `rust/benchmarks/results/v1/rust-search-cargo-floors-v1.json` | Queue/wake/shutdown verified. Representative same-semantics measurement closed via the cargo-first authoritative harness: Rust core search (full hits+context, JIT active) runs at p99 ~0.06-0.10 ms across the three representative fixtures over 5 process runs at HEAD `db53cf09` — an order of magnitude under the frozen runtime caps. The earlier `swift-search-reference` was firstMatch-semantics and is superseded (not comparable); no SLO cap or ratio was relaxed. |
| **G5 FFI Safety/Identity** | 1 binding boundary; 2 identity/admission | **Pass** | `ffi/src/api.rs::{initialization_rejects_build_fingerprint_mismatch,caught_panic_poison_rejects_later_exports,close_and_shutdown_are_idempotent}`; generated export/checksum manifest; focused bridge initialization/poison tests | The accepted boundary is limited to the synchronous proc-macro raw binder described below; no broader UniFFI capability is implied. |
| **G6 Reproducible Artifacts** | 6 deterministic generation/arm64 | **Pass** | two byte-for-byte identical generation runs; `make dev-cargo-codegen-check` / `regen --check` with zero diff; `identity.rs` eight input-sensitivity tests; generated manifest hashes; debug/release static archives verified as arm64-only | x86_64/universal output is neither produced nor accepted. |
| **G7 Swift/Link/Xcode** | 5 debug/release/race bridge; 7 Swift concurrency | **Pass** | focused `AgentryCoreBridgeTests` in debug, release, and ThreadSanitizer configurations; `Package.swift` Swift 6 strict concurrency plus warnings-as-errors for `AgentryUniFFIRaw`, `AgentryCoreBridge`, and `AgentryCoreBridgeTests`; `make xcode-rust-link-validate` authority | **Pass** (2026-08-21): release `RepoPromptTests.xctest` links 1268 Rust symbols surviving dead-strip (`nm`), its `.dSYM` resolves a Rust frame to source file:line via `atos` (`agentry_ffi::types::CoreCompactApplyEditsBatchResultV1::from` → `types.rs:1124`), demonstrating Rust DWARF flows into the dSYM pipeline. Rust v0-mangled names (`_RNv…`) require a v0-aware demangler downstream (Sentry symbolicator supports this); register per-release in the release-artifact checklist. |
| **G8 Governance** | 8 fuzz/security; cross-gate execution authority | **Pass with recorded caveat** — see ADR-0001's 2026-09-01 update | conductor Cargo operations and Make aliases; `.github/workflows/ci.yml` arm64 `rust-ffi` job; `make guardrails`; `python3 Scripts/test_contribution_preflight.py`; `cargo-fuzz` envelope smoke: 105,821,922 executions in 61 s, zero crashes, `cov=51` | The three blockers this row previously listed were verified closed against `ci.yml`/`preflight.sh`: (a) Rust PR-ready path selection **is** present (`preflight.sh:229` path pattern → `:269` selects `rust_tests`/`rust_codegen_check`/`rust_deny`/`rust_audit` → `:332-351` runs them); (b) deny/audit are pinned, `--locked`, and invoked unconditionally, not "only when available"; (c) bounded fuzz **and** bridge debug/release/TSan are all wired. **But configured is not executed — correction (2026-09-01):** the `rust-ffi` job died at its third step, `cargo fmt --all -- --check`, on a pre-existing comment-alignment drift in `agent_provider.rs`. Every step after it — workspace tests, `xtask generate --check`, `cargo deny`, `cargo audit`, all fuzz targets, and the bridge debug/release/TSan matrix — **had never executed**. That is why the export-inventory and fuzz-coverage drifts this change fixes survived: the gates that would have caught them were dead, not merely unwatched. The formatting blocker is fixed in this same change. **Scope of this verification:** only the three blockers this row itself named were checked; §15.2 item 8 was not re-enumerated clause by clause, and part of the fuzz coverage was completed in the same change. The decision owner ruled on 2026-09-01; [ADR-0001](adr-0001-uniffi-raw-binder.md)'s update section records the promotion, the caveat that this gate was *configured but not executing* until the `cargo fmt` blocker was removed, and the explicit note that closing evidence gaps does not widen the accepted capability boundary. |

UniFFI is the **accepted** raw binder (ADR-0001, user decision 2026-08-20), within the capability envelope proven by the gates. G4's representative same-semantics measurement is closed via the cargo-first floors (see G4 row); the G7 evidence-registration gap was closed 2026-08-21 with the release dead-strip/dSYM symbolication register. G1-G7 Pass; G8's listed blockers were verified closed 2026-09-01 and the decision owner promoted it the same day, with the "configured but not executing" caveat recorded in ADR-0001's update section rather than dropped.

> **Evidence-drift note (2026-09-01).** Until this revision the two G8 rows above contradicted each other and this sentence: the matrix row said **Pass** while the final-status row said **Conditional pass**, and both were stale. Root cause: this document was last revised 2026-08-22, while `ci.yml` kept moving (the `agent_command_v1` and `claude_ndjson_v1` fuzz targets were both added 2026-08-24; only the latter was wired into CI). The stale prose is what let that gap survive — the doc advertised "five fuzz jobs", so nobody was counting. Both rows' *factual* content is now reconciled against the workflow (the final-status verdict cell is deliberately left at Conditional pass for the decision owner), the missing target is wired in, and `Scripts/rust_ffi_guardrails.py::check_fuzz_target_coverage` fails closed if declared targets and CI steps diverge again. **When editing a G-row, verify against the workflow/script it cites, not against the neighbouring row.**

> **Cost-policy update (2026-09-04).** Hosted `CI` is Linux secret-scan only. Weekly `cargo audit` lives in `dependency-audit.yml`. Default local `cargo-test` is `--lib`. `preflight.sh` is whitespace, secrets, and guardrails; lint and tests are explicit. `check_fuzz_target_coverage` allows zero hosted fuzz steps.

Passing the Rust-side Phases 1–6 evidence alone is not evidence that the cross-language G3–G7 gates pass.

### Phase 5–6 G5/G7 evidence register (historical stage record)

- **G5 implementation evidence:** `rust/crates/ffi/src/api.rs`, `types.rs`, `errors.rs`, and `panic_guard.rs`; the unit tests in `api.rs` prove build-fingerprint mismatch rejection, first-panic `internalPanic` followed by `runtimePoisoned`, and idempotent subscription close/runtime shutdown. The generated export/checksum inventory is recorded by `rust/ffi-contract/generated-manifest.json`.
- **G7 evidence as of Phase 5–6:** `Sources/AgentryUniFFIRaw/Generated/AgentryCore.swift`, `Sources/CAgentryRustCore/include/AgentryCoreFFI.h`, and the ordinary (non-framework) `Sources/CAgentryRustCore/include/module.modulemap` were preparatory inputs only at that stage. The later cross-language compilation, link, and race evidence is registered in the final-status table and the Phase 7–8 register below.

### Phase 7–8 G1/G6 Swift evidence register

- **G1 Swift half:** `Package.swift` declares the private C/raw/bridge/test chain. `Sources/AgentryCoreBridge/` hides every generated record/object/error behind typed IDs, project errors, actor-isolated lifecycle, explicit Task cancellation, `DispatchSourceRead` draining, background payload decoding, RuntimeIdentity fencing, and project-owned `AsyncSequence` APIs. `Tests/AgentryCoreBridgeTests/` covers injected fingerprint rejection, real in-process initialization, cancel-before-admission, wake-driven `hasMore` drain, overflow gap/oversize projection, stale-object rejection, panic invalidation, and concurrent idempotent close.
- **G6 Swift/link half:** conductor operations `cargo-build`, `cargo-test`, `cargo-codegen`, and `cargo-archive` use the build lane, global heavy admission, `.build/cargo`, arm64, and macOS 14. `cargo-archive` publishes archive/header/manifest as one immutable generation, then atomically selects it through profile-specific and `.build/agentry-rust/current` symlinks; the Swift wrapper verifies profile plus SHA-256 manifest before invoking SwiftPM. `cargo-codegen --check` uses a private staging bundle and does not change `current`. `Sources/CAgentryRustCore/shim.c` supplies an actionable missing/stale ABI marker diagnostic.
- **Direct archive decision:** direct thin `.a` remains the selected format. Configuration-conditional absolute archive flags were rejected after this SwiftPM/Xcode toolchain injected the release path into a Debug test link. The evidence-backed adjustment is a build-lane-serialized `current` selection, not an XCFramework; the canonical debug/release archives remain separate.

### Strategic §15.2 technical gate evidence register

The strategic design numbers its binding-acceptance gates separately from the G1–G8 project gate matrix above. The requested Rust evidence is registered here to avoid conflating the two numbering systems:

| Strategic gate | Rust-side evidence now present | Remaining evidence |
|---|---|---|
| **§15.2 Gate 2 — Admission/cancel** | `runtime/tests/operation_registry.rs` covers cancel-before-admission, duplicate cancel, fingerprint/scope collision, deadlines, stale identity, and first-terminal-wins. `runtime/tests/randomized_lifecycle.rs` consumes every frozen seed and runs 12,000 admission/cancel schedules, asserting zero active operation/task leakage. `runtime/tests/runtime_lifecycle.rs` saturates the data lane and proves cancel plus nonblocking shutdown remain available. | Swift Task cancellation propagation and FFI admission/identity behavior are covered by focused `CoreOperationTests` and `CoreBridgeInitializationTests`; no P0 skeleton gap remains. |
| **§15.2 Gate 3 — Queue/wake/lifecycle** | `runtime/tests/subscription_backpressure.rs` covers count/byte overload, coalesced gaps, lossless terminal reserve, compact payload rejection, oversize drain without livelock, `hasMore`, terminal payload omission, and atomic snapshot/cursor bootstrap. `runtime/tests/wake_pipe.rs` covers nonblocking EAGAIN, coalesced wake, queue-lock rearm/recheck, dup ownership, idempotent/concurrent close, and identity replacement. `runtime/tests/shutdown_races.rs` proves bounded concurrent close/shutdown cleanup. | DispatchSource/Swift actor behavior and cross-FFI close races are covered by focused `CoreSubscriptionTests` and `CoreShutdownRaceTests`, including ThreadSanitizer execution. |
| **§15.2 Gate 4 — Representative payload benchmark** | Frozen synthetic shapes and absolute caps exist in `rust/benchmarks/fixtures/v1/synthetic/` and `rust/benchmarks/slo-v1.json`. | **Open P1 prerequisite:** no redacted real current-Swift baseline or observed comparison against the frozen SLOs has been recorded. Synthetic fixtures are not sufficient to close this item. |
| **§15.2 Gate 8 — Decoder security** | `proto/tests/envelope_v1.rs` consumes all frozen fixtures and uses 4,096 proptest cases per run across arbitrary bytes and adversarial declared lengths. It proves fail-closed handling for unknown schema/kind, nonzero flags, oversize declarations/envelopes, truncation, trailing bytes, invalid UTF-8, and decoded/collection/string limits before allocation. A bounded `envelope_decode` fuzz smoke completed 105,821,922 executions in 61 seconds with zero crashes and `cov=51`. | Envelope v1 has no compression field, so compressed-payload ratio limits remain inapplicable until a compressed schema is introduced. |

## ABI and envelope v1

The namespace is `agentry_core`; ABI epoch and envelope schema are both `1`.

Every data-plane envelope begins with a fixed 16-byte big-endian header:

| Offset | Width | Field | Contract |
|---|---:|---|---|
| 0 | 4 | magic | ASCII `AGRY` |
| 4 | 2 | schema version | unsigned integer; only `1` is accepted |
| 6 | 2 | payload kind | `1=control`, `2=data`, `3=hostRequest`, `4=hostResponse` |
| 8 | 4 | flags | must be zero in v1 |
| 12 | 4 | payload length | exact number of following bytes |
| 16 | variable | payload | maximum complete envelope is 1,048,576 bytes |

A decoder must validate magic, version, kind, flags, declared length, exact remaining length, and maximum size before allocating for the declared payload. It must reject trailing bytes, truncation, unknown version/kind, non-zero flags, and oversize payloads. It must never truncate or partially decode an oversize payload.

## Operation contract

- `OperationID` and `ScopeID` are lowercase canonical UUID strings.
- A request fingerprint is exactly 64 lowercase hexadecimal characters containing SHA-256.
- A deadline is Unix epoch milliseconds at the boundary. Admission converts it once to a remaining monotonic duration; an already-expired request never enters the registry.
- Reusing an operation ID with the same fingerprint and scope is idempotent and returns the existing state.
- Reusing it with a different fingerprint or scope returns `operationConflict`.
- Terminal tombstones live until runtime shutdown.
- Terminal resolution is first-terminal-wins. Later completion, cancellation, deadline, or shutdown observations may increment diagnostics but cannot replace the result.
- Cancellation, shutdown, terminal delivery, and host-control responses must remain available when the normal data lane is saturated.

The state inventory is `admitted`, `running`, `cancelRequested`, and `terminal(success|cancelled|deadlineExceeded|failed)`. Phase 3 owns implementation and deterministic/randomized proof.

## Runtime identity contract

Every raw call will explicitly carry a `RuntimeIdentity` containing:

- `abiEpoch: UInt32` (must equal 1);
- `instanceNonce`: 32 lowercase hexadecimal characters, unique per runtime instance;
- `buildFingerprint`: 64 lowercase SHA-256 hexadecimal characters;
- `bindingChecksum`: 64 lowercase SHA-256 hexadecimal characters.

An identity from a replaced or restarted runtime returns `staleRuntimeIdentity`. ABI, binding, or build mismatch fails before admission. A caught export panic atomically poisons the runtime identity; the panicking call returns `internalPanic`, and later calls return `runtimePoisoned`. Phase 5 implements these semantics with one shared guard entered by every object export.

## Frozen raw API inventory

`rust/ffi-contract/exports.txt` is the reviewable inventory. It freezes synchronous, fast admission/control/drain shapes only. The eventual Rust signatures are authoritative generated-binding inputs; no `.udl`, async foreign trait, payload callback, unversioned JSON, or UniFFI-owned Tokio runtime is permitted.

The closed error cases are:

`invalidArgument`, `incompatibleAbi`, `staleRuntimeIdentity`, `runtimePoisoned`, `runtimeStopped`, `operationConflict`, `deadlineExpired`, `subscriptionNotFound`, `queueLimitExceeded`, `payloadTooLarge`, `shutdownTimedOut`, and `internalPanic`.

The closed runtime event cases are:

`admitted`, `progress`, `data`, `gap`, `hostRequest`, `payloadRejected`, and `terminal`.

## SLO registry and baseline freeze

`rust/benchmarks/slo-v1.json` freezes absolute release/arm64 caps before candidate implementation measurements:

- admit, cancel, and empty drain: p99 at most 5 ms;
- drain of 64 events totaling at most 64 KiB: p99 at most 10 ms;
- empty-to-non-empty through DispatchSource handler scheduling: p99 at most 25 ms;
- 1,000 warm-up iterations and 10,000 measured samples;
- synthetic payload sizes of 0 B, 256 B, 64 KiB, and oversize.

No UniFFI export may sleep, await a Tokio task, or wait for queue space. Observed baseline data may not relax these caps by editing a fixture.

Actual current-Swift measurements for representative file-tree batches, codemaps, search results, and transcript batches are intentionally pending. Capturing them requires the later non-launching benchmark/export harness and is a prerequisite for the representative payload gate in Phase 8/10. Phases 1–2 freeze only the shape, redaction policy, stable inputs, and extraction/check tooling.

## Fixture policy

All committed Phase 0 fixtures are synthetic or explicitly pre-redacted. Raw workspace paths, usernames, repository content, prompts, transcript text, credentials, timestamps, random UUIDs, and machine identifiers are forbidden.

`Scripts/extract_rust_ffi_baselines.py` deterministically owns:

- protocol fixtures under `rust/crates/proto/tests/fixtures/v1/`;
- the envelope fuzz seed under `rust/fuzz/corpus/envelope_decode/`;
- synthetic representative payload shapes under `rust/benchmarks/fixtures/v1/synthetic/`;
- a manifest containing relative paths, byte sizes, and SHA-256 digests.

Run it with `--check` to prove committed output is reproducible. A later Swift exporter may write the same four JSON fixture names into a temporary directory. Importing with `--swift-export-dir` requires each root to declare `schemaVersion: 1`, the expected `fixtureKind`, and `redacted: true`; the script rejects forbidden keys/tokens, canonicalizes JSON, and emits `rust/benchmarks/fixtures/v1/swift-baseline/`. This import is not run in Phases 1–2, and that directory must not be populated with placeholder measurements.

Malformed protocol cases are deterministic:

- `empty.bin`: valid control envelope with zero payload;
- `small.bin`: valid data envelope with a fixed synthetic JSON payload;
- `truncated.bin`: declares four payload bytes but contains two;
- `unknown-version.bin`: otherwise valid envelope with schema version 2;
- `seed-v1.bin`: byte-identical to `small.bin`.

## Cargo workspace and dependency ownership

`rust/Cargo.toml` is a virtual workspace. Its Phase 0 active members are exactly `crates/proto`, `crates/runtime`, `crates/ffi`, and `tools/xtask`. Cargo rejects unmatched wildcard members, so the future grouping conventions `crates/domain/*`, `bins/*`, and `tools/*` become manifest globs only after their first owned crate exists.

The Phase 0 minimum therefore creates only `agentry-proto`, `agentry-runtime`, `agentry-ffi`, and `xtask`; empty domain and binary crates are deferred.

Dependency rules:

1. `agentry-proto` owns only the project envelope/schema boundary and has no Tokio or UniFFI dependency.
2. `agentry-runtime` depends on `agentry-proto`; later runtime behavior and Tokio ownership belong here, never in UniFFI.
3. `agentry-ffi` depends on runtime/proto and is the only product crate that depends on `uniffi = "=0.32.0"`.
4. `xtask` is not a default member and uses tooling-only `uniffi_bindgen = "=0.32.0"`. UniFFI 0.32.0 does not publish a separate `uniffi_bindgen_swift` crate on crates.io; Swift generation is owned by the version-matched bindgen distribution rather than a Git-only dependency.
5. Direct third-party dependencies are exact pins; transitive versions are frozen by the single committed `rust/Cargo.lock`.
6. Dev and release explicitly set `panic = "unwind"`; Cargo's test and bench harnesses use their fixed unwind behavior and reject the redundant profile key as ignored. Release retains debug info and is not stripped so later dSYM verification can resolve Rust frames.
7. Only `aarch64-apple-darwin` is configured. The final controlled target directory is repository `.build/cargo`; conductor will set deployment target 14.0 in Phase 7.

SwiftProtobuf and Google Protobuf are not dependencies in Phases 1–2. The strategic document still lists them as a candidate for representative-payload benchmarking; adopting them requires measured evidence and a separate lock/license decision. `Package.swift` and `Package.resolved` must remain unchanged here.

## Supply-chain policy

`rust/deny.toml` denies unknown registries/git sources, unlicensed crates, and explicitly denied license families while allowing the reviewed permissive/license set needed by the locked graph. Duplicate versions are warnings during the skeleton phase and become targeted bans only with evidence. `rust/audit.toml` contains no advisory exemption; every future exemption must include the advisory ID, rationale, owner, and expiration in the architecture record.

The fast `Scripts/rust_ffi_guardrails.py` validates manifests, exact UniFFI pins, profile/target policy, fixture reproducibility, lockfile presence, and the single UniFFI product owner without installing tools or accessing the network. `cargo deny` and `cargo audit` become coordinated CI gates in Phase 10. Missing local binaries are not installed as part of this phase.

## Phase 1–2 validation

Direct Cargo is transitional until conductor support exists. To avoid mutating the repository's existing Swift `.build` tree during this phase, local validation may override `CARGO_TARGET_DIR` with a temporary path while preserving the checked-in final target-dir policy.

```bash
python3 Scripts/extract_rust_ffi_baselines.py --check
python3 Scripts/rust_ffi_guardrails.py
CARGO_TARGET_DIR=/tmp/agentry-rust-phase2-target \
  cargo build --manifest-path rust/Cargo.toml --target aarch64-apple-darwin --locked
CARGO_TARGET_DIR=/tmp/agentry-rust-phase2-target \
  cargo test --manifest-path rust/Cargo.toml --locked
cargo tree --manifest-path rust/Cargo.toml -p agentry-ffi --locked
make guardrails
git diff --check
```

No command in this phase launches, stops, or relaunches Agentry.
