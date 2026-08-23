# P6-4 -- Rust process supervisor (cargo-only, no FFI): results

Design: `docs/designs/p6-claude-vertical-2026-08-23.md` §4 (process supervision contract), §11 (P6-4
step entry). Contract: `docs/architecture/rust-agent-claude-v1.md` §5 (process supervision
contract), §12 (dependency-surface delta). SLO registrations: `rust/benchmarks/slo-v1.json`
(`p6TwoResults.followUpConditions` records the four P6-4 prerequisites this document discharges;
`p6FourResults` records this step's own done-when evidence). Spike this step promotes from:
`rust/spikes/agent-claude-derisking-spike` (`src/spawn.rs`, `src/reaper.rs`) -- see that crate's own
`README.md`/`src/lib.rs` doc for what was a faithful port versus a scoped-down harness there.
Production code landed at `rust/crates/runtime/src/agent_claude/process/` (`spawn.rs`, `addchdir.rs`,
`reaper.rs`, `reader.rs`, `queue.rs`, `stderr_tail.rs`, `timer.rs`, `thread_budget.rs`).

**Overall verdict: GO.** Every P6-4 done-when item is evidenced below, cargo-only, zero FFI export
(INV-P6-1 holds trivially -- `cargo run --locked -p xtask -- generate --check` is zero-diff on
`exports.txt`/`abi-v1.json`, and `docs/architecture/source-layout.md`'s allowlist needs no new
entry since this step adds no new architecture doc). All four named P6-4 prerequisites this task
was scoped against are discharged, each with the actual evidence rather than a re-assertion of the
structural argument P6-2 used:

| # | Prerequisite | Discharge |
|---|---|---|
| 1 | Reaper reclamation policy -- close the §5.2 orphan-backstop map-entry reclamation gap | §2 below: provenance-typed registration (`register` vs `register_orphan`), not a time-based grace period |
| 2 | True coexistence testing -- replace the structural argument with a real measured arm | §3 below: two arms, honestly scoped -- Arm A (cheap regression net, not R2 evidence) and Arm B (the load-bearing adversarial foreign-owner measurement) |
| 3 | `addchdir_np` -- hand-declared `extern "C"` binding + scoped `unsafe_code` exception | §4 below |
| 4 | E-P6-1(a)/(b) real-traffic corpus remains user-blocked | Still blocked, unchanged from P6-2 (§7) -- named, not silently worked around |

## 1. Environment

- `rustc`/`cargo` 1.97.1 (pinned toolchain), target `aarch64-apple-darwin`.
- Sanitizers: `nightly-2026-08-15-aarch64-apple-darwin` via `+nightly -Zbuild-std`, matching the
  P6-2 spike's exact invocation pattern.
- `nix = "=0.30.1"` (features `fs, process, event, signal` -- unchanged from P6-1's pinning),
  `libc = "=0.2.189"` promoted from a transitive to a direct `agentry-runtime` dependency (`rust/
  Cargo.lock` diff is exactly one line -- the new dependency edge, no version change anywhere;
  `cargo deny check` reports `advisories ok, bans ok, licenses ok, sources ok`).
- `tokio` features unchanged: `{macros, rt, sync, time}` -- no `process`/`signal`/`net` added, per
  §4.1's `tokio::process` rejection. Now a standing guardrail (§6).

## 2. Reaper reclamation policy (prerequisite 1): provenance-typed registration

**The gap, as P6-2 found it.** `Reaper::register` issues a token; only the caller holding that
token can `wait_for_exit`/`forget` a completed entry. The orphan-backstop path (a scope dropped
without `shutdown`) has, by definition, no such caller -- so a completed orphan entry sat in the
map forever. The P6-2 soak measured this concretely: 40 of 400 `ScopeDropWithoutWait` cycles left a
permanently-resident entry.

**Rejected alternative: a time-based grace period.** The obvious fix -- reclaim any completed entry
after some duration past reaping -- was considered and rejected. `wait_for_exit` returns `Option`,
so a reclaimed-but-never-queried entry is indistinguishable from "still running" to any caller that
raced the grace window; a caller in an escalation path (`terminate_and_reap`) reading that `None`
would `killpg` a PID the OS may already have recycled. Tuning the grace duration cannot remove this
ambiguity, only make it rarer.

**The fix actually landed: provenance-typed registration.**

- `Reaper::register(pid) -> Result<u64, RegisterError>` -- **owned**. Unchanged from the spike:
  issues a token; the entry is reclaimed only by the caller's own explicit `forget(pid, token)`.
  Bounded by the same caller discipline `ProcessTermination.swift`'s registry already relies on.
- `Reaper::register_orphan(pid) -> Result<(), RegisterError>` -- **orphan**. Issues **no token**,
  so no caller can ever construct a valid `wait_for_exit`/`forget` call for this PID -- the
  "no waiter exists" property design §4.2 assumes is now enforced by the type signature, not by
  convention. The reaper reclaims the map entry itself, immediately, inside `reaper_complete`, the
  instant the reap resolves.
- `terminate_orphan_backstop(reaper, pid, poll_interval, grace)` is the orphan-backstop entry
  point: signals the group, registers as orphan, polls `is_registered` (itself token-free) to
  decide whether to escalate to SIGKILL after `grace`.

**Verified exact, not merely improved.** `rust/crates/runtime/src/agent_claude/process/reaper.rs`'s
own unit tests:

- `orphan_registration_leaves_zero_residual_entries` -- one cycle, asserts `registered_count() == 0`
  and `orphan_reclaim_count() >= 1` after reclamation.
- `orphan_backstop_soak_leaves_zero_residual_entries_across_many_cycles` -- **200** consecutive
  `ScopeDropWithoutWait`-shaped cycles (the P6-2 soak's exact 10%-cycle-type shape, scaled up), each
  individually asserted to leave zero residual entries. `registered_count() == 0` and
  `echild_count() == 0` at the end -- the P6-2 finding does not recur at 5x its own scale.

This closes the gap exactly, not statistically: an orphan entry's map residency is
`[registered, reaped]`, never longer, by construction rather than by a tuned bound.

## 3. Coexistence testing (prerequisite 2): two arms, honestly scoped

**Correction applied before landing, not after.** A first draft of this step planned a single arm
-- two independent `Reaper` instances running concurrently. Advisory review caught that this is
near-vacuous as an R2 measurement: two instances of the *same* PID-targeted code cannot steal from
each other by construction (every reap targets a specific PID via `waitid`/`waitpid`, never `-1`),
so running two of them side by side re-derives the structural argument P6-2 already made rather
than testing it. The design was split into two arms with that distinction stated plainly.

**Arm A -- `agent_claude_process_coexistence.rs`: two independent `Reaper` instances, 300 cycles
alternating between them.** A cheap regression net for accidental process-global state leaking
between instances (a shared kqueue fd, a shared token counter) -- **not** R2 evidence, and the
file's own module doc says so. Zero cross-attribution across 300 cycles; `echild_count() == 0` and
`registered_count() == 0` on both instances at quiesce.

**Arm B -- `agent_claude_process_coexistence_hostile.rs` (own binary, own process): the load-bearing
R2 measurement.** A genuinely adversarial foreign owner -- a background thread looping
`waitpid(-1, WNOHANG)`, process-wide, not PID-targeted -- races our reaper for the same 150 spawned
children. Isolated in its own binary because `waitpid(-1)` reaps *any* of the process's children and
would otherwise contaminate every other concurrently-running test in a shared test binary.

*Pass bar, stated honestly*: not "our reaper always wins the race" (not a guaranteed property
against an unbounded-scope hostile competitor, and claiming it would be dishonest) -- **every
registered PID resolves to a definite, correctly-typed outcome within a bounded time, never an
infinite hang, and a status the thief wins is surfaced as `ReapOutcome::Lost`
(`ChildOwnershipLost`), never silently misattributed.**

*Measured, one representative run*: 115 of 150 cycles won by our reaper (`Exited(0)`), 35 stolen by
the hostile thief and correctly surfaced as `Lost` -- `echild_count() == 35`, matching exactly; zero
hangs, zero misattributions, zero unexpected outcomes across all 150. The race is real (not
"structurally impossible to lose" by luck of scheduling) and every loss is typed and counted, never
silent.

**What this does and does not establish.** It does not certify coexistence against the *actual*
Swift `ChildStatusReaperRegistry` -- that needs the P6-6 FFI bridge (or a throwaway `dlopen` harness
judged out of proportion here, same call the P6-2 doc made). What it does establish, pre-bridge: our
reaper's detection-and-typing behavior under the worst adversarial pattern R2 names (a non-PID-
targeted competing reaper) is correct -- no hang, no silent theft, bounded resolution. Real
same-process Swift/Rust coexistence remains P6-6's to measure once the bridge exists; this is
recorded as inherited, not silently closed.

## 4. `addchdir_np` (prerequisite 3): landed

`rust/crates/runtime/src/agent_claude/process/addchdir.rs` -- one hand-declared `extern "C"`
binding for `posix_spawn_file_actions_addchdir_np` (confirmed absent from `nix` 0.30.1 and from
`libc` 0.2.189 on every Apple target, per P6-1/P6-2), plus one safe wrapper (`add_chdir`) that casts
`&mut PosixSpawnFileActions` to `*mut libc::posix_spawn_file_actions_t` -- sound because `nix`
declares `PosixSpawnFileActions` `#[repr(transparent)]` over exactly that type (verified by reading
`nix-0.30.1/src/spawn.rs` directly), guarded at runtime by a `debug_assert_eq!` on `size_of` so a
future `nix` upgrade that broke the layout assumption fails loudly rather than corrupting memory.

**Lint-table change required, and made narrowly, not crate-wide.** `rust/crates/runtime/src/lib.rs`
carried `#![forbid(unsafe_code)]`; `forbid` cannot be downgraded by any inner `#[allow(...)]`,
anywhere in the crate -- unlike `deny`. Both `rust/crates/runtime/Cargo.toml`'s `[lints]` table and
`lib.rs`'s crate attribute were changed from `forbid` to `deny`. **Two** `#[allow(unsafe_code)]`
sites exist in the crate, not one: `addchdir.rs` (this prerequisite) and
`reaper.rs::waitid_probe` (a second Apple-specific `nix` gap the P6-2 spike found -- `nix::sys::
wait::waitid` is gated off every Apple target, unlike `waitpid`, which the contract correctly
states is safe; `libc::waitid` is declared for Apple targets, so the fix is the same shape as
`addchdir_np` -- one small, well-encapsulated wrapper). Both sites, and no others, are now a
standing guardrail assertion (§6).

**`spawn.rs`'s "with cwd" configuration -- the P6-2 spike's named partial -- is now closed.**
`working_directory_is_honored` spawns `/bin/pwd` with a working directory and asserts the reported,
canonicalized path matches. E-P6-2 Part A's full 9-configuration matrix now runs as standing cargo
tests inside `agent_claude::process::spawn`'s own test module (baseline; custom env key; empty env
does not inherit; deep argv, 64 args; argv with spaces + multi-byte UTF-8; missing binary → ENOENT;
non-executable → EACCES; shell-forks-a-grandchild-that-stays-in-group; working directory) plus
config 9 (SIGKILL escalation, reaper-owned) in `agent_claude::process::reaper`'s own tests.

## 5. Reader threads, framer wiring, synthetic-CLI matrix, TSan

`rust/crates/runtime/src/agent_claude/process/reader.rs` implements INV-P6-2 against the real,
byte-exact `agent_claude::framer::LineFramer` (P6-3-landed) -- not the P6-2 spike's raw-`\n`-split
harness. Stderr gets a separate 256 KiB tail (`stderr_tail.rs`), not framed like stdout, matching
contract §5.4.

**`tests/support/synthetic_cli.rs`** is a dependency-free, portable stand-in for `claude` (a `[[bin]]`
target, never shipped) covering design §3.4's named matrix plus E-P6-3's rows: `well-behaved`,
`hostile-ignore-sigterm`, `silent`, `huge-line`, `crash-on-signal`, `flood`, `mid-line-stall`,
`stdin-starved-flood`. Chosen over `python3`/shell scripting so the matrix has no dependency on
system Python's presence or path.

**`tests/agent_claude_process_reader.rs`**, 7 tests, all green:

- `well_behaved_single_line_is_framed_and_queued`
- `huge_line_triggers_framer_overflow_and_reader_does_not_hang` -- 9 MiB line (over the 8 MiB cap);
  overflow diagnostic fires, reader does not hang. (The eventual truncated-tail line is itself large
  enough to exceed the queue's own byte cap and evict the earlier diagnostic entry from the ring --
  asserted at the reader-stats level instead of via queue presence, since that eviction is the
  bounded queue's own correct pressure-relief policy, not a defect to fight in the test.)
- `mid_line_stall_completes_without_deadlock` -- a 300 ms mid-object stall still completes.
- `silent_then_well_behaved_reader_does_not_falsely_terminate` -- a 1 s silence, then a line.
- `flood_bounded_memory_and_zero_terminal_loss` -- a terminal event pushed mid-flood survives via
  the reserved slot; peak queue bytes never exceed the registered 1 MiB cap.
- `deadlock_probe_stdin_starved_flood_reader_never_stalls` -- the named E-P6-3 deadlock probe: a
  child floods stdout and never reads stdin; the parent's stdin write blocks once the pipe fills;
  the stdout reader's loop-iteration heartbeat is observed advancing throughout, direct evidence it
  is unaffected.
- `crash_on_signal_reader_reaches_clean_eof` -- a child that raises `SIGABRT` against itself (not
  `SIGSEGV`: Rust's std runtime installs its own SIGSEGV handler for stack-overflow-guard-page
  detection, which observed a `raise(SIGSEGV)` with no genuine faulting address and simply returned
  rather than re-raising during this test's development, letting the child exit(0) instead of
  terminating by signal -- recorded rather than silently worked around). Reader reaches EOF cleanly;
  the reaper separately reports `Signaled(SIGABRT)` for the same child.

**TSan/ASan.** `RUSTFLAGS="-Z sanitizer=thread"` and `"-Z sanitizer=address"`, both via
`+nightly -Zbuild-std --target aarch64-apple-darwin`, both `--test-threads=1`:

- Lib unit tests (`agent_claude::process::*`, 24 tests): **TSan clean, ASan clean.**
- `agent_claude_process_reader` (7 tests): **TSan clean, ASan clean.**
- `agent_claude_process_coexistence` (Arm A): **TSan clean, ASan clean.**
- `agent_claude_process_coexistence_hostile` (Arm B): **TSan clean, ASan clean.**

This directly discharges the P6-2 results doc's own named follow-up: "get a real TSan pass on the
stream-reader harness specifically... once it is production P6-3/P6-4 code."

**Named reduction, not silently skipped**: the N=1/4/16 thread-budget test and the 1,000-session
leak soak (§6) were **not** run under ASan/TSan -- each real spawn+reader+reaper session multiplies
instrumentation overhead, and the soak's own uninstrumented wall-clock cost is already ~44 s;
sanitizer instrumentation was judged disproportionate for a soak whose correctness property
(thread-count bookkeeping) is already covered by the sanitizer-clean unit/integration tests above
exercising the identical `spawn`/`reader`/`reaper` code paths at smaller N.

## 6. Thread budget, missed-`NOTE_EXIT` self-heal, timer primitive, guardrails

**`AGENT_DOMAIN_THREAD_COUNT` centralized.** Originally placed inside `reaper.rs` (mirroring the
spike), it was moved to a neutral `thread_budget.rs` module once reader threads needed to
contribute to it too -- a single shared instrument rather than two counters a caller has to
remember to sum. `reader.rs`'s spawn functions increment synchronously in the *spawning* thread
(before the new thread starts, avoiding a race where a caller checks the counter before the new
thread has been scheduled) and decrement via an RAII guard constructed first inside the new
thread's own closure (correct on panic-unwind, not just normal return).

**`tests/agent_claude_process_thread_budget.rs`**, one test function (deliberately -- see the file's
own comment: two separate `#[test]` fns asserting before/after deltas against a process-global
counter would race each other under the harness's default concurrent-test execution):

- N = 1, 4, 16 concurrent real sessions (real `spawn` + two real reader threads + real reaper
  registration each): thread count is exactly `2N + 1` while sessions are live, and returns to the
  exact pre-N baseline after every N.
- 1,000-session leak soak: 50 batches of 20 concurrent real sessions; thread count returns to the
  pre-soak baseline after every batch, never accumulating.

**`missed_kevent_is_self_healed_by_the_periodic_sweep`** (`reaper.rs`'s own tests): a test-only
`register_without_kevent_for_test` bypasses `EVFILT_PROC` registration entirely, so the periodic
0.5 s sweep is the *only* reachable path to an outcome for that PID. Succeeding proves the sweep
path, by construction -- no other mechanism exists for it to have resolved through. (An earlier
version of this test additionally asserted the `missed_kevent_self_heals` diagnostic counter's exact
value; that assertion proved sensitive to scheduling-instrumentation timing under a TSan build --
around exactly which sweep pass's pending-PID snapshot first observes this specific PID -- and was
dropped as a bookkeeping nicety, not the property this test exists to prove.)

**Timer primitive (design §4.7).** `timer.rs` provides a deadline-based `Deadline<Clock>` --
recomputed against `clock.now()` on every poll, never accumulated from slept durations, which is
what makes it discontinuity-safe by construction. Three tests parameterize the design's three
pinned durations (reaper probe 0.5 s; idle fallback 1.0 s, P6-5's to consume; interrupt-ACK deadline
1.5 s, P6-5's to consume) against a `FakeClock` that jumps forward discontinuously in one step
(modeling a sleep-length clock discontinuity structurally, since this crate cannot suspend the OS
inside `cargo test` -- see the module's own doc for exactly what this does and does not claim about
real sleep/wake, which stays P6-8's soak to measure). The reaper's own periodic sweep now consumes
this same primitive (`reaper.rs`'s `run_loop`) rather than duplicating an ad hoc `Instant::elapsed()`
comparison.

**Guardrails (`Scripts/rust_ffi_guardrails.py`), all new, all green**: `agentry-runtime`'s `tokio`
features stay exactly `{macros, rt, sync, time}`; its `nix` features stay exactly `{event, fs,
process, signal}`; exactly two `#[allow(unsafe_code)]` sites exist in `rust/crates/runtime/src`, at
exactly `agent_claude/process/addchdir.rs` and `agent_claude/process/reaper.rs`; `lib.rs` carries
`#![deny(unsafe_code)]`, not `#![forbid(unsafe_code)]`. `./Scripts/guardrails.sh` (identity, source
layout, contributor allowlist, SwiftPM notices, Codex vendor, headless runtime) passes unchanged.

## 7. What remains blocked, unchanged from P6-2

E-P6-1(a)/(b) and E-P6-3(e)/D-8's cap derivation remain blocked on the same real-traffic corpus gap
P6-2 named and this task's brief called out as user-blocked up front. Nothing in this step attempts
a synthetic workaround for that gate; P6-3's own done-when (already landed, cargo-only, zero FFI)
is unaffected since it does not depend on P6-4. Real same-process Swift/Rust reaper coexistence
(§3's honest caveat) remains P6-6's to measure once the FFI bridge exists.

## 8. Validation summary

- `cargo test -p agentry-runtime` (full crate, including all P6-3 and pre-existing tests): 333 lib
  tests + all integration binaries green (`make dev-cargo-test CARGO_PACKAGE=all`, coordinated).
- `cargo run --locked -p xtask -- generate` then `-- generate --check`: zero-diff on the second run;
  the first run's regeneration is fingerprint-only (`bindingChecksum`/`expectedExports` unchanged in
  `rust/ffi-contract/generated-manifest.json` -- confirms INV-P6-1 holds, no new FFI surface).
- `cargo deny check`: `advisories ok, bans ok, licenses ok, sources ok`.
- `make dev-swift-build PRODUCT=Agentry`: green (only pre-existing, unrelated deprecation
  warnings).
- `make dev-lint`: green (Swift-side; unaffected by this Rust-only step).
- `./Scripts/guardrails.sh`: green, including the two new Rust FFI guardrail assertions above.
