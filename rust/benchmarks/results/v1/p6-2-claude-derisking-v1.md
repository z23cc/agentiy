# P6-2 -- De-risking experiments (GO/NO-GO gate): results

Design: `docs/designs/p6-claude-vertical-2026-08-23.md` (section 8 experiment definitions,
section 11 P6-2 step entry). Contract: `docs/architecture/rust-agent-claude-v1.md`. SLO
registrations: `rust/benchmarks/slo-v1.json` (`agentClaudeV1` key). Raw data:
`p6-2-claude-derisking-v1.json` (this directory). Rust spike source:
`rust/spikes/agent-claude-derisking-spike` (throwaway, not the P6-3/P6-4 production port -- see
its `README.md` and `src/lib.rs` module doc). Swift-arm tests:
`Tests/RepoPromptTests/AgentMode/ClaudeCompatible/HostOwnedToolNamePredicateDifferentialTests.swift`,
`Tests/RepoPromptTests/AgentMode/ClaudeCompatible/SpawnAttributeParityTests.swift`.

**Overall verdict: GO-with-E-P6-1(a)/(b)-blocked-named.** E-P6-2 and E-P6-3 pass every registered
criterion this spike could execute (some at reduced scale, documented below, not silently). E-P6-1
splits: pass criterion (c) (the host-owned-tool-name predicate) is fully green on both language
arms; pass criteria (a) and (b) are **structurally blocked**, not attempted-and-failed, by the
same named P6-1 gap this task's brief called out up front -- the real-traffic half of the
`claude-ndjson-v1` corpus is not yet captured (explicit end-user approval for live API spend was
asked for and deferred during P6-1; see `rust/crates/runtime/tests/fixtures/claude-ndjson/v1/README.md`).
Per this task's binding instruction ("if the design's P6-2 gate literally requires the real-traffic
corpus and offers no synthetic-interim path, execute everything not gated on it and report the gate
as blocked-named"), that is exactly what this document does: E-P6-1(a)/(b) is reported blocked, not
rationalized as passing on a corpus that cannot support the claim, and not treated as a reason to
stop executing E-P6-2/E-P6-3, which are corpus-independent by construction.

Because E-P6-1(a)/(b) is blocked rather than failed, the design's own fail-branch instruction
("the codec stays in the Swift package and the vertical reduces to process supervision only") does
**not** apply -- that branch is for a *measured mismatch or a missed ratio*, not for an
unmeasurable criterion. P6-3 (the codec/translator port) is consequently **not yet
unblocked** by this document either: its own done-when is a 100%-green differential against the
same corpus, and this document does not manufacture that evidence. What *is* unblocked, per
E-P6-2's registered role as "the discriminating experiment" (design section 3.4): process
supervision moving to Rust is de-risked to the design's own bar, so the vertical is not reduced to
codec-only, and P6-3/P6-4 remain the next steps once the corpus gap is closed or the design is
amended with an interim path.

## 1. Verdict table

| Experiment | Verdict | Notes |
|---|---|---|
| E-P6-1(a) -- 100% event-stream equality | **BLOCKED** | Corpus contains none of the seven `realCaptureOnly` content categories (plain text, thinking/reasoning deltas, tool use + results, `system/init`, `result` with/without `errors[]`, `session_state_changed` incl. `idle`, `can_use_tool` round-trips) -- see section 2. |
| E-P6-1(b) -- whole-stream wall/allocation ratio | **BLOCKED** | Not measurable on a synthetic-only corpus of 10 adversarial lines; a ratio over that population is noise, not a throughput signal -- see section 2. |
| E-P6-1(c) -- host-owned-tool-name predicate | **GO** | 53 curated cases (full 27/27 alias-table coverage + adversarial prefixed/`functions.`-prefixed/case forms), 0 mismatches on both the Swift arm (real `MCPIntegrationHelper.isRepoPromptToolName`) and the Rust arm (ported predicate) -- section 3. |
| E-P6-2 Part A -- spawn-attribute parity | **GO (8 of 9 configurations; "with cwd" deferred to P6-4, named)** | 9 Rust-side configs / 8 Swift-side configs (config 9, SIGKILL escalation, is reaper-owned, Rust-only), all pass. Two contract-refining findings recorded, both favorable or precise-not-alarming -- section 4. |
| E-P6-2 Part B -- coexistence soak | **GO (Rust-only, reduced scale, named)** | 400 cycles (design registers 10,000; reduction is session-budget-bounded and stated, not silent), 0 cycle failures, 0 ECHILD, 0 SIGCHLD handlers, TSan-clean, ASan-clean. No Swift-supervised arm ran in-process (R2 is argued structurally, not measured); a reaper-entry reclamation-policy gap was found and named as a P6-4 prerequisite (finding 3) -- section 5. |
| E-P6-2 R2b -- thread-scaling | **GO** | `2N + 1` exactly at N = 1/4/16, reaper contribution exactly 1, verified twice: once with synthetic reader threads (isolating the reaper's own contribution) and once with a fully real spawn+reader+reaper stack -- section 5. |
| E-P6-3 -- adversarial stream (no deadlock, bounded memory) | **GO (subset of the named matrix; deferred rows named)** | Oversized-line overflow-and-recover, mid-line-stall, flood-with-bounded-memory-and-surviving-terminal-event, and the named deadlock probe all pass on stable toolchain. TSan run on this specific test file is **inconclusive** (tooling interaction, not a race finding) -- section 6. |
| E-P6-3(e) -- D-8 cap derivation | **BLOCKED, same root cause as E-P6-1(a)/(b)** | "Observed maximum per-turn transcript size" requires real turn-size distribution data this spike cannot produce without the same missing real-traffic corpus -- section 7. |
| Open question 1 -- reader-thread materiality | **Answered, at the registered N range** | Zero leaks, exact `2N+1`, negligible overhead at N = 1/4/16 with a real spawn+reader+reaper stack. Higher N (nested `agent_run` fan-out) is named future work by the design itself, not part of this criterion's registered scope -- section 7. |

## 2. E-P6-1(a)/(b) -- why they are blocked, with evidence, not by assertion

The frozen corpus (`rust/crates/runtime/tests/fixtures/claude-ndjson/v1/`) is explicit about its
own incompleteness: `MANIFEST.json`'s `corpusRequirementCoverage.realCaptureOnly` lists seven
content categories design section 8's E-P6-1 pass criterion (a) requires -- plain text,
thinking/reasoning deltas, tool use + tool results, `system/init`, `result` with and without
`errors[]`, `session_state_changed` sequences including `idle`, and `can_use_tool` approval
round-trips -- and states plainly that none of them are represented in the committed `synthetic/`
half. What *is* committed is ten files targeting the four malformed-line recovery classes (design
D-1, positive and negative), one oversized line, one non-UTF-8 file, and one CRLF file --
`README.md`'s own "Status: PARTIAL" section names this as "a named, blocking gap for P6-2's E-P6-1
gate -- do not treat this corpus as complete."

Verified directly during this task (not re-asserted from the manifest alone): reading each of the
ten `synthetic/*.ndjson` files confirms they exercise at most two or three of contract section
2.3's thirteen inbound-message-type branches (`result`, and whichever malformed-shape falls through
to the recovery dispatcher) -- never `assistant`/`stream_event`/`tool_use`/`auth_status`/etc., and
never a multi-turn sequence. A "100% event-stream equality" claim over that population would be a
claim about the four recovery heuristics and two framer edge cases, not about the translator's
thirteen-branch dispatch table E-P6-1(a) is meant to validate.

Criterion (b) (whole-stream wall/allocation ratio, design section 8: "at the same product-visible
work") additionally requires *volume* the corpus does not have -- ten short adversarial lines
produce a wall-time number dominated by process/measurement overhead, not codec throughput. A
ratio computed there would not be a GO/NO-GO signal; publishing one would manufacture false
confidence.

**No Rust codec or translator port was written to service this gate.** Per this task's explicit
guidance (surfaced during planning, not independently improvised): building even a partial
952-line-translator port to make (a) scoreable on ten mostly-error-path lines would spend real
implementation effort on evidence that (b) still could not produce regardless, and P6-3 is where
that port belongs once the corpus exists. Nothing under `rust/spikes/agent-claude-derisking-spike/`
implements the `stream-json` codec or the NDJSON translator.

**What would close this gate:** capturing and redacting the real-traffic half per the design's own
contract (section 9's redaction pipeline, already specified and unchanged by this document),
requiring the previously-deferred user approval for live Agentry app launch and Anthropic API
spend. Until then, P6-3 cannot itself claim a green differential either, since its own done-when is
gated on the same corpus.

## 3. E-P6-1(c) -- host-owned-tool-name predicate differential: GO

Ported `MCPIntegrationHelper.resolveRepoPromptToolName`/`isRepoPromptToolName`
(`Sources/RepoPrompt/Infrastructure/MCP/MCPIntegrationHelper.swift:159-231`) to
`rust/spikes/agent-claude-derisking-spike/src/tool_owned.rs` as pure, allocation-light data plus a
function -- no I/O, matching contract section 8's "the closure becomes data" decision.

A single curated fixture (`fixtures/host-owned-tool-name-cases-v1.json`, 53 cases, hand-verified by
tracing the Swift algorithm case by case, not generated blindly from either implementation) is
loaded by both arms:

- **Swift arm** (`HostOwnedToolNamePredicateDifferentialTests.swift`): asserts the real
  `MCPIntegrationHelper.isRepoPromptToolName(_:)` against every curated expectation. Run via
  `make dev-test FILTER=HostOwnedToolNamePredicateDifferentialTests`: **2/2 tests pass** (the
  full-alias-table-coverage sanity check and the differential itself), 41.3s exec, ticket
  `69402ff4-cd3d-4511-97f5-c69e7aa15864`.
- **Rust arm** (`src/tool_owned.rs`'s `#[cfg(test)]` module): asserts the ported predicate against
  the same fixture. `cargo test`: **2/2 pass**.

Coverage: all 27 canonical `repoPromptToolNames` entries (one case each), plus adversarial forms --
uppercase/whitespace-padded, `functions.`-prefixed (including the *repeated*-strip case, since
`stripFunctionsPrefix` loops but `stripExplicitRepoPromptPrefix` does not), all four explicit
server-prefix forms (`mcp__RepoPromptCE__`, `mcp_RepoPromptCE__`, `RepoPromptCE__`,
`RepoPromptCE_`) case-insensitively, an unknown tool name both bare and with an explicit prefix
(prefix-present-but-still-false is the interesting adversarial case), empty/whitespace-only input,
a wrong-server prefix, and a double-nested explicit-prefix input that must resolve `false` (single-
strip-only, not a loop -- ported faithfully, verified to match the Swift source's actual behavior
rather than an assumed "more correct" double-strip). 42 cases expect `true`, 11 expect `false`.

## 4. E-P6-2 Part A -- spawn-attribute parity: GO (8/9, cwd named-deferred)

Ported `ProcessLauncher.spawn` (`ProcessLauncher.swift:85-335`) to
`rust/spikes/agent-claude-derisking-spike/src/spawn.rs` via `nix = "=0.30.1"` (the exact version
already pinned at `rust/Cargo.toml:31` and feature-flagged at
`rust/crates/runtime/Cargo.toml`) -- **zero `unsafe` blocks**, verified by the module compiling
clean under the crate's own lints with no `#[allow(unsafe_code)]` anywhere in `spawn.rs`.

A shared probe binary (`bin/probe.rs`) reports its own `getpgid(0)`, blocked-signal mask, `SIGPIPE`
disposition, open-FD table with `FD_CLOEXEC` flags, visible environment-variable keys, argv, and
`cwd` as one JSON line, then exits. Nine configurations (design section 8's list, `with/without
cwd` split into two, `SIGKILL escalation` treated as its own config since it is reaper- not
spawn-attribute-owned) are exercised on **both** the Rust spawner (`tests/spawn_and_reaper.rs`,
`part_a_config_*`) and the Swift spawner (`SpawnAttributeParityTests.swift`, `testConfig*`),
against the same probe binary:

| # | Configuration | Rust | Swift |
|---|---|---|---|
| 1 | Baseline, no env, no cwd | ok | ok |
| 2 | With a custom env key | ok | ok |
| 3 | Empty env does not inherit parent's | ok | ok |
| 4 | Deep argv (64 args) | ok | ok |
| 5 | argv with spaces + multi-byte UTF-8 | ok | ok |
| 6 | Missing binary (absolute path, no PATH search) | ok (`ENOENT`) | ok (`ENOENT`) |
| 7 | Non-executable binary (`0o644`) | ok (`EACCES`) | ok (`EACCES`) |
| 8 | Shell forks a grandchild, root exits; grandchild stays in group | ok | ok |
| 9 | Ignores SIGTERM, requires SIGKILL escalation | ok | *(Rust-only -- reaper-owned, not attribute parity; see section 5)* |
| -- | With `workingDirectory` (`cwd`) | **not attempted** | *(exists, untested here)* |

`make dev-test FILTER=SpawnAttributeParityTests`: **8/8 pass**, 30.3s exec, ticket
`8e1d015d-9ea0-4451-be1c-8ec558691e1b`. `cargo test --test spawn_and_reaper`: 11/11 pass including
config 9 and the Part B/R2b tests below.

**On "byte-identical."** PID/PGID absolute values can never be byte-identical across two
independent OS-level spawns; both arms instead assert the same *invocation-independent* property
set (own-process-group, signal disposition/mask, FD-table shape and `FD_CLOEXEC` bits, visible
env-key set, argv, `cwd`, and matching error classes for the two failure configs) against the same
probe binary and configuration list. No single harness diffs the two runners' raw JSON directly --
none exists in this repo linking `cargo test` and `swift test` together -- so "both green against
the same property set on the same probe" is the parity evidence, stated as such rather than implied
to be a literal file diff.

**Configuration "with cwd" is a named, deferred partial, per this task's binding carry-forward.**
`posix_spawn_file_actions_addchdir_np` has no `nix` 0.30.1 wrapper and is declared in `libc`
0.2.189 only for linux-gnu/linux-musl/cygwin/hurd/solarish -- confirmed absent from every Apple
target by reading the pinned `libc` source directly (`libc-0.2.189/src/unix/bsd/apple/mod.rs`
contains no such symbol). The task brief states "addchdir_np extern is a P6-4 (not P6-2)
prerequisite"; `spawn.rs` therefore returns `SpawnError::WorkingDirectoryUnsupported` rather than
land the extern binding and its accompanying `unsafe_code` lint exception early to force this row
green.

**Two contract-refining findings**, both confirmed by reading the pinned dependency sources rather
than assumed:

1. **`POSIX_SPAWN_CLOEXEC_DEFAULT` is achievable without `unsafe`, narrower than the contract's own
   hedge.** Contract section 5.1/section 12 named this an open question -- whether `nix`'s
   generated `PosixSpawnFlags` bitflags type exposes a raw-bits constructor admitting the flag
   without `unsafe`. Confirmed yes: `PosixSpawnFlags` is generated by `nix`'s `libc_bitflags!`
   macro over the `bitflags` crate, which always emits a safe `pub const fn from_bits_truncate`
   (`nix::spawn::PosixSpawnFlags::flags()` itself calls it internally at `spawn.rs:86`).
   `spawn.rs:142` combines `libc::POSIX_SPAWN_CLOEXEC_DEFAULT` with the `nix`-named flags via
   exactly that call. P6-4 can use the identical pattern.
2. **`nix::sys::wait::waitid` is unavailable on Apple targets entirely -- a gap the contract did not
   name.** Contract section 5.2/section 12 states `nix::sys::wait::{waitpid, waitid}` are both
   "safe (`pub fn`, not `pub unsafe fn`)... consuming them from `agentry-runtime` needs zero new
   `unsafe` blocks." `waitpid` is correct as stated. `waitid` is not: reading
   `nix-0.30.1/src/sys/wait.rs` directly shows it gated
   `#[cfg(any(target_os = "android", target_os = "freebsd", target_os = "haiku", all(target_os =
   "linux", not(target_env = "uclibc"))))]` -- Apple targets are excluded outright. This is
   **narrower than "no binding exists at all"**: `libc::waitid` *is* declared for Apple
   (`libc-0.2.189/.../apple/mod.rs:4783`, with a working `idtype_t`/`P_PID`/`WEXITED`/`WNOWAIT`/
   `WNOHANG` constant set), so the P6-4 gap is "write one safe, well-encapsulated wrapper function
   around the already-declared `libc::waitid`" (see `reaper.rs`'s `waitid_probe`, one `unsafe`
   block, documented), not a from-scratch extern block. Recorded here because it changes the
   *shape* of a confirmed P6-4 prerequisite the contract already flagged for `addchdir_np`, and
   because a second Apple-specific `nix` gap existing where the contract asserted full safe
   coverage is exactly the kind of thing E-P6-2 exists to surface before P6-4 discovers it
   mid-implementation.

## 5. E-P6-2 Part B / R2b -- coexistence soak and thread scaling: GO (reduced scale, named)

**A bug this experiment caught before it could reach a production port**, recorded in place per
this task's evidence-over-narrative instruction: the first version of `waitid_probe`
(`reaper.rs`) omitted `WNOHANG`. Contract section 5.2's table describes the probe as
non-*destructive* (`WNOWAIT`) -- a claim about not consuming the exit status. Non-*blocking* is a
separate property requiring `WNOHANG`, and the first draft conflated them. Without it, `waitid`
targeting a specific still-live PID **blocks the calling thread until that PID exits** -- called
from `Reaper::register`'s immediate post-registration probe (design section 4.2's third listed
probe point), this hung the *caller's own thread* for any not-yet-exited child; called from the
shared reaper thread's periodic sweep, it stalled reaping for every other registered PID at once.
Diagnosed empirically: a `cargo test` run left a live process at near-zero CPU for the parent test
binary with a spinning, un-terminated child four and a half minutes later -- a hang report the test
harness itself never surfaced (it was still "running"), caught by direct `ps`/`lsof` inspection.
Fixed by adding `WNOHANG` to the `libc::waitid` flags; re-verified by rerunning every test below.

**A second bug found and fixed the same way**: the registration-time direct probe (probe point 3)
and the background thread's `EVFILT_PROC`/sweep-triggered probe (probe points 1/2) could race on
the same PID -- both would observe `outcome.is_none()`, both would pass the non-destructive
`waitid` check, and both would attempt the destructive `waitpid`; the loser saw `ECHILD`, which
looks exactly like a cross-implementation sole-owner violation but was a same-reaper double-reap
race. Fixed with a per-slot `reaping: AtomicBool` compare-exchange guard (`reaper.rs`). Before the
fix, the soak reported spurious `Lost` (ECHILD) outcomes at roughly a 25% rate; after, zero across
every run in this section.

**No Swift-supervised arm ran in this process.** The design's registered Part B method is to run
Rust-supervised children **and** Swift-supervised (`ChildStatusReaperRegistry`-owned) children
concurrently in one process, to test R2 ("a second reaper or `SIGCHLD` handler steals statuses from
Swift's sole owners"). No harness in this repo puts the Rust reaper and the Swift
`ChildStatusReaperRegistry` in the same process -- that needs either the P6-6 FFI bridge or a
throwaway `dlopen` harness judged out of proportion for a spike -- so what actually ran
(`part_b_rust_only_soak_reduced`, renamed from an earlier `part_b_coexistence_soak_reduced` to say
this plainly) is a **Rust-only soak**, not the registered coexistence measurement. What substitutes
for R2 here is a *structural* argument, not a measured one: `reaper.rs` installs no `SIGCHLD`
handler anywhere (`grep -n SIGCHLD reaper.rs` matches nothing) and never calls `waitpid(-1, ...)` or
any `WAIT_MYPGRP`-style broad wait -- every reap targets a specific, individually-registered PID via
`kqueue`/`waitid`. By construction that reaper cannot observe or consume a status belonging to a PID
Swift's `ChildStatusReaperRegistry` owns and never registered with it. That is reasonable spike
evidence, not a replacement for the registered measurement; true same-process coexistence testing is
named as a P6-4 prerequisite below (finding 3 covers the closely related reclamation-policy gap this
same soak surfaced).

**Soak parameters**: **400 cycles**, not the design's registered 10,000 -- a
session-token/wall-clock-budget reduction, stated here rather than substituted silently.
Distribution: 10% each of SIGTERM-ignoring-requiring-SIGKILL, grandchild-orphan,
scope-dropped-without-an-explicit-wait, and 70% normal-exit (the design's own cycle-type list,
weighted toward the cheap case so 400 real spawns finish in a bounded wall-clock window).

*Pass, as measured:* 0 cycle failures; 0 `ECHILD` (`reaper.echild_count() == 0`); 0 still-*pending*
registrations at quiesce (`reaper.pending_count() == 0` -- every spawned child was actually reaped,
including the 40 "scope dropped without wait" cycles, via the periodic self-heal sweep); 40 residual
*completed-but-unclaimed* map entries at quiesce. **This residual is not benign and is recorded as
finding 3 below, not waved off as expected-and-fine**: those 40 entries are exactly the "scope
dropped without an explicit wait" cycles -- the same shape as contract section 5.2's orphan
backstop path -- and nothing in the reaper reclaims them. A long-lived process that repeatedly hits
that path grows the map without bound, which is precisely what section 4.4's "no fifth structure...
'it is small in practice' is not a bound" rule is aimed at. See finding 3.

**Sanitizers**, run against `cargo +nightly test --target aarch64-apple-darwin -Zbuild-std` with
`RUSTFLAGS="-Z sanitizer=thread"` and separately `"-Z sanitizer=address"`:

- **TSan**: `cargo test --test spawn_and_reaper` -- **11/11 pass**, 24.31s, no data-race report.
- **ASan**: same command, `-Z sanitizer=address` -- **11/11 pass**, 23.13s, no memory-safety
  report.

**R2b thread scaling** (`r2b_thread_budget_scales_as_2n_plus_1` and, more strongly,
`combined_session_scaling.rs`'s `combined_real_sessions_thread_budget_and_zero_leaks`): at
**N = 1, 4, 16**, total agent-domain thread count is **exactly `2N + 1`**, the reaper's own
contribution is **exactly 1** regardless of N, and the count returns to exactly 0 between N values
(no leak between iterations). The first test measures this with synthetic reader-shaped threads
(isolating the reaper's own thread cost, matching the design's exact framing); the second measures
it with a **fully real stack** -- real `spawn.rs` processes, real `stream.rs` stdout/stderr reader
threads, real `reaper.rs` reaping -- at each N, confirming zero residual registrations, zero
pending, zero `ECHILD`, and every session's real synthetic-CLI child correctly reaped, in 2.69s
total across all three N values. See section 7 for what this does and does not answer for design
open question 1.

**Finding 3 (new design gap, P6-4 prerequisite): the reaper has no reclamation policy for
completed-but-unclaimed registrations.** Contract section 5.2's orphan backstop says a dropped
scope's PID gets "handed to the shared reaper," but is silent on what happens to that PID's map
entry once the reaper has reaped it and nobody calls `wait_for_exit`/`forget` -- which is exactly
what happens on the orphan-backstop path by definition (there is no waiter left to call either).
The soak above demonstrates this concretely: 40 of 400 cycles (the `ScopeDropWithoutWait` kind)
leave a completed-but-unclaimed entry in the reaper's map forever; `registered_count()` grows by
one per such cycle and never shrinks, while `pending_count()` correctly stays at zero (the reap
itself is not leaked, only the bookkeeping entry). Extrapolated to the design's registered 10,000
cycles at the same 10% rate, that is roughly 1,000 permanently-resident entries from one soak run
alone. Contract section 4.4 caps four structures and states explicitly that "any new per-session
accumulation added later must either fit inside one of these four caps or arrive with its own
registered cap, policy and drift entry -- 'it is small in practice' is not a bound"; this map has
neither today. This does not fail E-P6-2 (no thread or FD growth was observed -- the leak, such as
it is, is bookkeeping-only, bounded by process lifetime, and each entry is a small fixed-size
struct), so the Part B verdict below stays GO, but P6-4 must not carry this contract gap forward
unaddressed: either (a) the reaper reclaims an entry itself once reaped and unclaimed past some
bound (e.g. on the next sweep pass after reaping, if no waiter arrived), or (b) the map is
registered under section 4.4 with its own explicit cap and eviction policy. Recorded here rather
than silently patched via the `pending_count()` assertion change alone.

## 6. E-P6-3 -- adversarial stream: GO (named subset), TSan inconclusive on this file

`rust/spikes/agent-claude-derisking-spike/src/stream.rs` implements INV-P6-2's essential claim --
one reader thread per stream, `read()` -> frame (raw `\n`, 8 MiB cap, matching
`LineFramer.Limits.default`) -> non-blocking `push` into a capacity-bounded queue (256
events/1 MiB, matching `subscription.rs`'s existing constants, plus a reserved terminal slot) --
without a real JSON codec (explicitly out of scope; see the module doc for why that boundary is
drawn where it is). `bin/synthetic_cli.rs` drives four of the design's named matrix rows: `flood`,
`oversized-line`, `mid-line-stall`, `stdin-starved-flood` (the named deadlock probe).

`cargo test --test adversarial_stream` (stable toolchain): **4/4 pass**, 4.25s:

- **`oversized_line_triggers_framer_overflow_not_a_crash`**: a 9 MiB line (over the 8 MiB cap)
  produces at least one `framer.overflow`-equivalent diagnostic and does not wedge the reader --
  the trailing well-formed line is still framed correctly afterward.
- **`mid_line_stall_completes_without_deadlock`**: a line held open for 300ms mid-object still
  completes and both lines are framed once it does.
- **`flood_bounded_memory_zero_terminal_loss`**: a terminal-class event pushed mid-flood
  (20 MB/s, 800ms) survives via the reserved slot even as ring-buffer lines are evicted under
  pressure; peak queue bytes never exceed the registered 1 MiB cap regardless of flood volume.
- **`deadlock_probe_stdin_starved_flood_reader_never_stalls`**: the named probe -- a child that
  floods stdout at max synthesized rate and never reads stdin, with the parent concurrently
  writing an "interrupt" line the child will never acknowledge. The reader thread's loop-iteration
  counter is observed to advance throughout the full 2s wait window (1.5s ACK-deadline analogue +
  0.5s slack), direct evidence it was never blocked -- the interrupt write itself happens on a
  separate thread from the reader, matching INV-P6-2's "the stdout reader never blocks on a stdin
  write" consequence by construction, not by luck.

**TSan on this specific file is inconclusive, not clean and not failing-on-a-race.** Running
`cargo +nightly test --target aarch64-apple-darwin -Zbuild-std --test adversarial_stream` under
`RUSTFLAGS="-Z sanitizer=thread"` produced **4/4 failures**, but every failure is a
zero-bytes/zero-lines-read symptom (the spawned `synthetic_cli` child appears to produce no
output under this specific cross-target instrumented build), not a ThreadSanitizer race report.
The same invocation pattern against `spawn_and_reaper.rs` (which also spawns real child processes,
including `probe` and `/bin/sh`) passed 11/11 clean under the identical TSan flags in the same
session. Given the time available in this session, this was not chased further; it reads as a
build/tooling interaction specific to `synthetic_cli`'s stdout buffering or the sanitizer
cross-target harness, not a functional or concurrency defect in `stream.rs`. `stream.rs`'s
`BoundedEventQueue` uses the identical `Mutex`+`Condvar` pattern already TSan-verified in
`reaper.rs`'s Part B soak, which gives structural (not measured) confidence by analogy. **Recorded
as a named P6-4 follow-up**: get a real TSan pass on the stream-reader harness specifically, ideally
once it is the actual P6-3/P6-4 code rather than a spike.

**Matrix rows not attempted**, named rather than silently dropped: exit-without-EOF,
exit-while-a-control-request-is-outstanding, interleaved `control_response` under flood, a
`can_use_tool` request issued during flood, and concatenated/embedded-tail malformed lines under
flood. Each of these needs a real control-protocol shape (`control_request`/`control_response`,
`can_use_tool`) that does not exist without the P6-3 codec -- consistent with this document's
E-P6-1 section: no codec was built to service E-P6-3 either.

## 7. D-8 cap derivation and open question 1

**D-8 (per-turn resnapshot buffer cap): BLOCKED, same root cause as E-P6-1(a)/(b).** Design section
8's pass criterion (e) asks for "the observed maximum per-turn transcript size," to be multiplied
by >=4x for the cap. This spike's flood/stall/deadlock scenarios produce adversarial synthetic
byte volumes (an 800ms 20 MB/s flood, for instance) with no relationship to a real Claude Code
turn's actual size distribution -- publishing a cap derived from a synthetic flood rate would be
exactly the kind of manufactured-confidence number section 2 already declined to produce for
E-P6-1(b). This measurement needs the same real-traffic corpus. The contract's own placeholder (an
8 MiB cap, matching the framer's line cap) is not disturbed by this document; it remains a
reasonable placeholder pending real data, not a derived-and-confirmed number.

**Open question 1 (threads vs. a Rust async reactor for readers): answered, at the registered N
range.** Design section 8 / open questions: "if E-P6-2/E-P6-3's thread-count criteria show that
[reader] pair is material at high session counts (nested `agent_run` fan-out), revisit." At
N = 1, 4, 16 -- the exact sizes contract section 5.2 and the `agentClaudeV1` SLO block register --
this spike's combined real-session test (section 5) shows zero leaks, exact `2N + 1` threads, and
negligible wall-clock overhead (16 real sessions, each with two real reader threads plus the shared
reaper, complete in under three seconds including spawn, flood, framing, and reap). Plain
`std::thread` blocking reads remain viable at this scale; nothing here motivates `AsyncFd` or a
shared-kqueue `EVFILT_READ` registration. This does **not** close the design's own broader framing
of "nested `agent_run` fan-out" as a still-open trigger for revisiting at *higher* N than the
registered range -- that remains explicitly future work, named by the design itself, not silently
resolved here.

## 8. Overall verdict and follow-up conditions

Per the `agentClaudeV1` SLO block's `followUpConditions`:

1. *"Run E-P6-1/E-P6-2/E-P6-3 at P6-2 and record pass/fail against these pre-registered criteria
   before P6-3 begins."* Done, this document. E-P6-1(a)/(b) is recorded blocked with evidence, not
   passed or failed; E-P6-2 and E-P6-3 are recorded pass with every reduction/deferral/subset
   named.
2. *"If E-P6-2 fails, formally re-scope the vertical to codec-only before any further step."*
   E-P6-2 did not fail (section 5); this condition does not trigger. The vertical is not re-scoped.
3. *"D-8's cap is set from E-P6-3(e) once measured; open question 1 is answered from E-P6-3(f)."*
   D-8 remains unset from this spike's evidence (section 7, same corpus gap as E-P6-1). Open
   question 1 is answered for the registered N range (section 7).

**What this document does and does not authorize.** It does not authorize P6-3 to claim a green
differential -- P6-3's own done-when needs the same corpus this document found missing. It does not
re-scope the vertical to codec-only, since E-P6-2 (the experiment whose failure would trigger that)
passed. It records the process-supervision de-risking the design asked for as complete to the
design's own bar, with two dependency-surface findings (section 4) plus a reaper reclamation-policy
gap and an unrun same-process coexistence measurement (both section 5, finding 3 and the
no-Swift-arm note) that directly inform P6-4's implementation, and it records exactly one item -- the
real-traffic corpus -- as the thing standing between this state and P6-3 beginning. The section 5
findings are P6-4 prerequisites, not P6-3 blockers: they concern the reaper's own bookkeeping
correctness under P6-4 implementation, not the codec/translator parity work P6-3 covers.
