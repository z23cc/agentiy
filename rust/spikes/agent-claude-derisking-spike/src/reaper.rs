//! E-P6-2 Part B / R2b: a shared-kqueue reaper mirroring `ChildStatusReaperRegistry`
//! (`Sources/RepoPrompt/Infrastructure/Process/ProcessTermination.swift:58-232`) per contract
//! section 5.2 -- **one** process-wide kqueue fd, **one** process-wide reaper thread (zero per
//! child), `EVFILT_PROC`/`NOTE_EXIT` per registered PID, a periodic non-destructive sweep standing
//! in for the Swift registry's per-PID `DispatchSourceTimer` fallback probe (see
//! [`Reaper::run_loop`] doc for why one shared periodic tick is the chosen substrate here), the
//! `waitid(..., WNOWAIT)`-then-`waitpid` two-step, and a PID+token sole-owner guard.
//!
//! **Confirmed gap, precisely stated (refines contract section 5.2/section 12's own hedge).**
//! `nix::sys::wait::waitid` is gated `#[cfg(any(target_os = "android", target_os = "freebsd",
//! target_os = "haiku", all(target_os = "linux", not(target_env = "uclibc"))))]` in nix 0.30.1 --
//! it excludes every Apple target outright (verified by reading `nix-0.30.1/src/sys/wait.rs`
//! directly during this spike; the contract's own text does not name this gap for `waitid`,
//! only for `addchdir_np`). This is **not** "no binding exists": `libc::waitid` **is** declared for
//! Apple targets (`libc-0.2.189/src/unix/bsd/apple/mod.rs:4783`, confirmed by direct read) with a
//! working `idtype_t`/`P_PID`/`WEXITED`/`WNOWAIT` constant set. The P6-4 gap is therefore narrower
//! than "write a hand-rolled `extern "C"` block": it is "write one safe, well-encapsulated wrapper
//! function around the already-declared `libc::waitid`", isolated to [`waitid_probe`] below and
//! requiring exactly one `unsafe` block -- still a confirmed, unconditional `unsafe_code`
//! prerequisite for P6-4's spawner/reaper module (this spike is not bound by the workspace
//! `unsafe_code = "forbid"` lint, so it is used directly here).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use nix::sys::event::{EvFlags, EventFilter, FilterFlag, KEvent, Kqueue};
use nix::sys::signal::{killpg, Signal};
use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
use nix::unistd::Pid;

/// Count of OS threads spawned "by the agent domain" in this process: per-session stdout/stderr
/// reader threads (E-P6-3) plus this module's one shared reaper thread. E-P6-2 Part B / R2b's
/// pass criterion (`2N + 1` at N = 1/4/16, reaper contribution exactly 1) is asserted against this
/// counter -- an in-process instrument, not OS thread enumeration -- matching contract section
/// 5.2's framing ("total process thread count attributable to the agent domain"). A per-child
/// reap thread (the regression design section 4.2 / F1 removed) would show up here as `3N`.
pub static AGENT_DOMAIN_THREAD_COUNT: AtomicUsize = AtomicUsize::new(0);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReapOutcome {
    Exited(i32),
    Signaled(i32),
    /// `ProcessTerminationError.childOwnershipLost` (`ProcessTermination.swift:44-51`): the
    /// kernel reported ECHILD for a PID this reaper still believed it owned. Surfaced as a typed
    /// diagnostic outcome, not a panic, per design D-4's "counted diagnostic, not `assertionFailure`"
    /// discipline.
    Lost,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegisterError {
    /// Mirrors `ProcessTerminationError.childOwnershipLost` (`ProcessTermination.swift:44-51`):
    /// the reaper is not the sole potential owner of this PID's status.
    AlreadyRegistered,
}

struct Slot {
    token: u64,
    outcome: Mutex<Option<ReapOutcome>>,
    condvar: Condvar,
    /// Claims exclusive probe/reap rights for this PID. Without this, the registration-time
    /// direct probe (probe point 3) and the background thread's EVFILT_PROC/sweep-triggered probe
    /// (probe points 1/2) can race: both observe `outcome.is_none()`, both pass `waitid`'s
    /// non-destructive check, and both attempt the destructive `waitpid` -- the loser sees ECHILD
    /// because the status was already consumed by the winner, which looks exactly like a
    /// cross-implementation sole-owner violation but is purely a same-reaper double-reap bug.
    /// Discovered empirically: this spike's own soak initially reported spurious `Lost` (ECHILD)
    /// outcomes at a ~25% rate before this guard was added.
    reaping: std::sync::atomic::AtomicBool,
}

struct Shared {
    kq: Kqueue,
    entries: Mutex<HashMap<i32, Arc<Slot>>>,
    next_token: AtomicU64,
    shutdown: std::sync::atomic::AtomicBool,
    /// Diagnostics, mirroring the Rust-side counted-diagnostic-not-panic discipline (design D-4).
    pub echild_count: AtomicUsize,
    pub missed_kevent_self_heals: AtomicUsize,
    pub reap_count: AtomicUsize,
}

pub struct Reaper {
    shared: Arc<Shared>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

/// One safe, encapsulated wrapper around the already-declared `libc::waitid` (see module doc for
/// why this -- not a from-scratch extern block -- is the confirmed P6-4 shape). Non-destructive:
/// `WNOWAIT` keeps the status waitable so this probe never consumes it, mirroring
/// `ProcessTermination.swift:174-200`'s `waitid(...WNOWAIT)`-then-`waitpid` two-step.
/// **Bug found and fixed during this spike, recorded rather than silently corrected**: the first
/// version of this function omitted `WNOHANG`. Contract section 5.2's table describes the probe as
/// non-*destructive* (`WNOWAIT`), which is a claim about not consuming the exit status -- it is a
/// separate property from non-*blocking*, which requires `WNOHANG`. Without `WNOHANG`, `waitid`
/// targeting a specific still-live PID **blocks the calling thread until that PID actually exits**
/// -- which, called from `Reaper::register`'s immediate post-registration probe on the *caller's
/// own thread*, meant `register()` itself hung for any not-yet-exited child, and called from the
/// shared reaper thread's periodic sweep, stalled reaping for every other registered PID at once.
/// This is exactly the class of bug E-P6-2 exists to catch before it reaches a production port;
/// see the P6-2 results doc for how it was diagnosed (a live process stuck at 0% parent CPU with a
/// runaway child, not a hang report from the test harness itself).
fn waitid_probe(pid: i32) -> Result<bool, i32> {
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    // SAFETY: `info` is a valid, owned, zero-initialized `siginfo_t` for the duration of the call;
    // `libc::waitid` writes into it and returns success/errno per POSIX. `WNOWAIT` guarantees this
    // call cannot consume the child's exit status (non-destructive); `WNOHANG` guarantees it
    // cannot block the calling thread (non-blocking) -- both properties are required, independently.
    let rc = unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            &mut info as *mut libc::siginfo_t,
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };
    if rc != 0 {
        let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(-1);
        return Err(errno);
    }
    // With WNOHANG and no reportable state change, waitid succeeds (rc == 0) but leaves `si_pid`
    // at 0 -- that is the "still alive, nothing to report" case, distinguished here from "this PID
    // actually exited" by checking the reported pid matches the one we targeted.
    Ok(info.si_pid == pid)
}

/// SIGTERM -> grace -> SIGKILL against the *group* (own children only), mirroring
/// `ProcessTermination.swift:446-487`'s two-stage escalation. Uses `killpg` because every spawned
/// child is its own process-group leader (`spawn.rs`'s `set_pgroup(0)`), matching design section
/// 4.2's "escalation parity" row.
pub fn terminate_and_reap(reaper: &Reaper, pid: i32, token: u64, grace: Duration) -> Option<ReapOutcome> {
    let target = Pid::from_raw(pid);
    let _ = killpg(target, Signal::SIGTERM);
    if let Some(outcome) = reaper.wait_for_exit(pid, token, grace) {
        return Some(outcome);
    }
    let _ = killpg(target, Signal::SIGKILL);
    reaper.wait_for_exit(pid, token, Duration::from_secs(2))
}

/// Probes and, if the entry is still pending (`outcome` unset), attempts to reap `pid`. Skips
/// entries whose outcome is already set -- `EVFILT_PROC` is registered `EV_ONESHOT` so the kernel
/// will not re-fire for an already-reaped PID, but the periodic sweep walks every registered PID
/// unconditionally, so this guard is what keeps the sweep from re-`waitid`ing an already-completed
/// slot (which would spuriously report `ECHILD`, since the status is already consumed).
fn reaper_probe_and_reap(shared: &Shared, pid: i32) {
    let slot = {
        let entries = shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.get(&pid).cloned()
    };
    let Some(slot) = slot else {
        return; // not our PID (never registered, or already forgotten)
    };
    if slot
        .outcome
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .is_some()
    {
        return;
    }
    // Sole-owner-within-this-reaper guard (see `Slot::reaping` doc): only the caller that wins
    // this compare-exchange actually issues `waitid`/`waitpid` for this PID on this pass.
    if slot
        .reaping
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return;
    }
    match waitid_probe(pid) {
        Ok(true) => reaper_destructive_reap(shared, pid),
        Ok(false) => {}
        Err(errno) if errno == libc::ECHILD => {
            shared.echild_count.fetch_add(1, Ordering::SeqCst);
            reaper_complete(shared, pid, ReapOutcome::Lost);
        }
        Err(_) => {}
    }
    slot.reaping.store(false, Ordering::SeqCst);
}

fn reaper_destructive_reap(shared: &Shared, pid: i32) {
    match waitpid(Pid::from_raw(pid), Some(WaitPidFlag::WNOHANG)) {
        Ok(WaitStatus::Exited(_, code)) => reaper_complete(shared, pid, ReapOutcome::Exited(code)),
        Ok(WaitStatus::Signaled(_, sig, _)) => reaper_complete(shared, pid, ReapOutcome::Signaled(sig as i32)),
        Ok(WaitStatus::StillAlive) | Ok(_) => {}
        Err(nix::Error::ECHILD) => {
            shared.echild_count.fetch_add(1, Ordering::SeqCst);
            reaper_complete(shared, pid, ReapOutcome::Lost);
        }
        Err(_) => {}
    }
}

/// Records the outcome in-place (does **not** remove the map entry -- [`Reaper::wait_for_exit`]
/// needs to observe it even if called after completion already happened, and the periodic sweep's
/// "already done" guard above needs `entries.get(&pid)` to keep resolving). Callers reclaim the
/// entry explicitly via [`Reaper::forget`] once they have consumed the outcome, keeping the map
/// bounded across a long soak rather than growing once per historical child.
fn reaper_complete(shared: &Shared, pid: i32, outcome: ReapOutcome) {
    let slot = {
        let entries = shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.get(&pid).cloned()
    };
    shared.reap_count.fetch_add(1, Ordering::SeqCst);
    if let Some(slot) = slot {
        let mut guard = slot.outcome.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        *guard = Some(outcome);
        slot.condvar.notify_all();
    }
}

impl Reaper {
    pub fn new() -> Arc<Reaper> {
        let shared = Arc::new(Shared {
            kq: Kqueue::new().expect("kqueue() must succeed"),
            entries: Mutex::new(HashMap::new()),
            next_token: AtomicU64::new(1),
            shutdown: std::sync::atomic::AtomicBool::new(false),
            echild_count: AtomicUsize::new(0),
            missed_kevent_self_heals: AtomicUsize::new(0),
            reap_count: AtomicUsize::new(0),
        });
        let run_shared = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("agent-reaper".to_string())
            .spawn(move || Self::run_loop(run_shared))
            .expect("spawning the shared reaper thread must succeed");
        AGENT_DOMAIN_THREAD_COUNT.fetch_add(1, Ordering::SeqCst);
        Arc::new(Reaper {
            shared,
            thread: Mutex::new(Some(thread)),
        })
    }

    pub fn echild_count(&self) -> usize {
        self.shared.echild_count.load(Ordering::SeqCst)
    }

    pub fn missed_kevent_self_heals(&self) -> usize {
        self.shared.missed_kevent_self_heals.load(Ordering::SeqCst)
    }

    pub fn reap_count(&self) -> usize {
        self.shared.reap_count.load(Ordering::SeqCst)
    }

    pub fn registered_count(&self) -> usize {
        self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner).len()
    }

    /// Count of entries still awaiting an outcome (`outcome.is_none()`). Unlike
    /// [`Self::registered_count`], this excludes completed-but-not-yet-[`forget`](Self::forget)ten
    /// entries -- e.g. a "scope dropped without an explicit wait" registration that the periodic
    /// sweep already self-healed but nobody has reclaimed. Zero here is the real "no leaked reap
    /// ownership" property; `registered_count() - pending_count()` is residue.
    ///
    /// **This residue is a genuine open design gap, not just an unmodeled harness detail.**
    /// Contract section 5.2's orphan backstop hands an orphaned PID to the shared reaper but does
    /// not say who reclaims the map entry afterward, and section 4.4's four-structure cap has no
    /// slot registered for "completed-but-unclaimed reaper entries". A long-lived process that
    /// repeatedly drops scopes without an explicit `shutdown`/`forget` (exactly the orphan-backstop
    /// path) will grow this map without bound. P6-4 must either add a reclamation policy to the
    /// contract (e.g. `forget`-on-reap for orphan-backstop entries with no waiter) or register this
    /// map under section 4.4 with its own cap -- see the P6-2 results doc, section 5, finding 3.
    pub fn pending_count(&self) -> usize {
        let entries = self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries
            .values()
            .filter(|slot| {
                slot.outcome
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .is_none()
            })
            .count()
    }

    /// Registers a PID for exit notification. Three probe points, matching contract section 5.2's
    /// table exactly: (1) an immediate non-blocking `waitid(WNOHANG|WNOWAIT)` check right after
    /// EVFILT_PROC registration (covers the exited-before-we-registered race); (2) the periodic
    /// sweep inside [`Self::run_loop`] (covers a missed kevent under load); (3) EVFILT_PROC's own
    /// wake (the common case). Returns [`RegisterError::AlreadyRegistered`] if this PID already has
    /// an owner in this reaper -- the sole-owner guard, checked before insertion.
    pub fn register(&self, pid: i32) -> Result<u64, RegisterError> {
        let token = self.shared.next_token.fetch_add(1, Ordering::SeqCst);
        {
            let mut entries = self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if entries.contains_key(&pid) {
                return Err(RegisterError::AlreadyRegistered);
            }
            entries.insert(
                pid,
                Arc::new(Slot {
                    token,
                    outcome: Mutex::new(None),
                    condvar: Condvar::new(),
                    reaping: std::sync::atomic::AtomicBool::new(false),
                }),
            );
        }
        let changelist = [KEvent::new(
            pid as usize,
            EventFilter::EVFILT_PROC,
            EvFlags::EV_ADD | EvFlags::EV_ONESHOT,
            FilterFlag::NOTE_EXIT,
            0,
            0,
        )];
        let mut eventlist = [KEvent::new(0, EventFilter::EVFILT_READ, EvFlags::empty(), FilterFlag::empty(), 0, 0); 1];
        // Registration-boundary probe point 1 -- registering can race an already-exited child;
        // this call both submits the changelist and (with a zero timeout) returns immediately.
        let _ = self.shared.kq.kevent(&changelist, &mut eventlist[..0], Some(zero_timespec()));
        // Registration-boundary probe point 2 (direct post-activate probe, contract section 5.2's
        // third row) -- covers a child that exited between spawn and this `register` call.
        reaper_probe_and_reap(&self.shared, pid);
        Ok(token)
    }

    /// Blocks the caller until this PID's slot is reaped or `timeout` elapses. `token` must match
    /// the value [`Self::register`] returned -- the sole-owner guard: if `pid` was reaped and
    /// re-registered under a new token while this call was waiting (only possible with PID reuse,
    /// which the OS defers until the wait_pid slot is freed), a mismatched token means "not your
    /// registration" and this returns `None` rather than a stale/foreign outcome.
    pub fn wait_for_exit(&self, pid: i32, token: u64, timeout: Duration) -> Option<ReapOutcome> {
        let slot = {
            let entries = self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            entries.get(&pid).cloned()
        };
        if let Some(slot) = &slot {
            if slot.token != token {
                return None;
            }
        }
        let slot = slot?;
        let guard = slot.outcome.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let (guard, _timeout_result) = slot
            .condvar
            .wait_timeout_while(guard, timeout, |o| o.is_none())
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *guard
    }

    /// Reclaims a completed entry after the caller has consumed its outcome via
    /// [`Self::wait_for_exit`], keeping the map bounded across a long soak. No-op if `pid` is not
    /// registered or `token` does not match the current registration.
    pub fn forget(&self, pid: i32, token: u64) {
        let mut entries = self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if entries.get(&pid).is_some_and(|slot| slot.token == token) {
            entries.remove(&pid);
        }
    }

    /// Stops the shared reaper thread and joins it, decrementing [`AGENT_DOMAIN_THREAD_COUNT`].
    /// Idempotent, matching `ProcessTermination.swift`'s `shutdown()` idempotency (contract
    /// section 5.2's `shutdown idempotency` row).
    pub fn shutdown(&self) {
        self.shared.shutdown.store(true, Ordering::SeqCst);
        if let Some(handle) = self.thread.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take() {
            let _ = handle.join();
            AGENT_DOMAIN_THREAD_COUNT.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// The reaper thread body. Registration-boundary probe point 3 (contract section 5.2's
    /// "repeating fallback timer" row): rather than a second `EVFILT_TIMER` kevent registration
    /// alongside `EVFILT_PROC`, this spike uses `Kqueue::kevent`'s own `timeout` argument as the
    /// periodic tick -- functionally equivalent (the thread wakes every 500ms regardless of
    /// whether a real event arrived) and avoids a second changelist entry per PID. Recorded as a
    /// legitimate spike-level simplification in the P6-2 results doc; P6-4's production port may
    /// choose either shape.
    fn run_loop(shared: Arc<Shared>) {
        let tick = tick_timespec(500);
        let mut eventlist =
            [KEvent::new(0, EventFilter::EVFILT_READ, EvFlags::empty(), FilterFlag::empty(), 0, 0); 64];
        let mut last_sweep = std::time::Instant::now();
        loop {
            if shared.shutdown.load(Ordering::SeqCst) {
                break;
            }
            let n = shared.kq.kevent(&[], &mut eventlist, Some(tick)).unwrap_or(0);
            for ev in &eventlist[..n] {
                if ev.filter() == Ok(EventFilter::EVFILT_PROC) {
                    reaper_probe_and_reap(&shared, ev.ident() as i32);
                }
            }
            // Periodic self-heal sweep: "kevent exit delivery is not contractual under load"
            // (`ProcessTermination.swift:99-105`). Probe every still-registered PID even when the
            // wake above was itself the timeout firing with zero events.
            if last_sweep.elapsed() >= Duration::from_millis(500) {
                let pending_pids: Vec<i32> = {
                    let entries = shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    entries
                        .iter()
                        .filter(|(_, slot)| {
                            slot.outcome
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .is_none()
                        })
                        .map(|(pid, _)| *pid)
                        .collect()
                };
                for pid in pending_pids {
                    reaper_probe_and_reap(&shared, pid);
                    let now_done = {
                        let entries = shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                        entries.get(&pid).is_some_and(|slot| {
                            slot.outcome
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .is_some()
                        })
                    };
                    if now_done {
                        // This PID was still pending at the top of the sweep and is done now --
                        // the EVFILT_PROC/NOTE_EXIT kevent for it was missed or never delivered,
                        // and the periodic sweep is what caught it. This is the self-heal the
                        // fallback-timer property exists to provide.
                        shared.missed_kevent_self_heals.fetch_add(1, Ordering::SeqCst);
                    }
                }
                last_sweep = std::time::Instant::now();
            }
        }
    }
}

impl Drop for Reaper {
    /// Belt-and-braces cleanup so a panicking caller (e.g. a failed test assertion) cannot leak
    /// the shared reaper thread -- and its [`AGENT_DOMAIN_THREAD_COUNT`] contribution -- into
    /// whatever runs next in the same process. `shutdown` is idempotent, so this is a no-op if
    /// the caller already shut the reaper down explicitly.
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn zero_timespec() -> libc::timespec {
    libc::timespec { tv_sec: 0, tv_nsec: 0 }
}

fn tick_timespec(millis: i64) -> libc::timespec {
    libc::timespec {
        tv_sec: millis / 1000,
        tv_nsec: (millis % 1000) * 1_000_000,
    }
}
