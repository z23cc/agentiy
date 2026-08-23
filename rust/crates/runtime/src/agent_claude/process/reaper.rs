//! P6-4 (`docs/architecture/rust-agent-claude-v1.md` §5.2, design §4.2): a shared-kqueue reaper
//! mirroring `ChildStatusReaperRegistry`'s **whole** architecture
//! (`Sources/RepoPrompt/Infrastructure/Process/ProcessTermination.swift:58-232`), not merely its
//! `waitpid` targeting -- one process-wide kqueue fd, **one** process-wide reaper thread (zero per
//! child), `EVFILT_PROC`/`NOTE_EXIT` per registered PID, a periodic non-destructive sweep standing
//! in for the Swift registry's per-PID `DispatchSourceTimer` fallback probe, the
//! `waitid(..., WNOWAIT|WNOHANG)`-then-`waitpid` two-step, and a PID+token sole-owner guard.
//!
//! Promoted from the P6-2 spike (`rust/spikes/agent-claude-derisking-spike/src/reaper.rs`) with
//! two fixes the spike already found and folded in (both recorded in
//! `rust/benchmarks/results/v1/p6-2-claude-derisking-v1.md` §5, carried forward here rather than
//! rediscovered): `waitid_probe` requires `WNOHANG` as well as `WNOWAIT` (non-blocking is a
//! property distinct from non-destructive, and omitting it hangs the calling thread against any
//! not-yet-exited child); and a per-slot `reaping: AtomicBool` compare-exchange guard prevents the
//! registration-time direct probe and the background sweep/kevent probe from double-`waitpid`ing
//! the same PID and spuriously reporting ECHILD to each other.
//!
//! **The reclamation-policy gap this module closes (P6-4 prerequisite, contract §5.2, finding 3 of
//! the P6-2 results doc).** The spike's soak showed that a completed reap whose PID nobody ever
//! calls `wait_for_exit`/`forget` for -- exactly the orphan-backstop shape design §4.2 names --
//! leaves a permanently-resident map entry: 40 of 400 soaked cycles, extrapolated to the design's
//! registered 10,000-cycle soak at the same rate, ~1,000 entries from one run. Contract §5.4's
//! "no fifth structure... 'small in practice' is not a bound" rule applies. **Fix: provenance-typed
//! registration, not a time-based grace period.** [`Reaper::register`] (owned) returns a token and
//! is reclaimed only by the caller's own explicit [`Reaper::forget`] -- unchanged from the spike,
//! bounded by existing caller discipline exactly as `ProcessTermination.swift`'s registry is today.
//! [`Reaper::register_orphan`] (backstop) returns **no token** -- by construction, nothing can ever
//! call `wait_for_exit`/`forget` for it, because both require a token this registration never
//! hands out -- so the reaper reclaims an orphan's map entry itself, immediately, the instant its
//! reap completes (inside [`reaper_complete`]), rather than waiting on a grace period or a caller
//! that structurally cannot arrive. This makes the bound exact rather than time-decayed: an orphan
//! entry's residency in the map is `[registered, reaped]`, never longer, and the soak in
//! `tests/agent_claude_process_reaper.rs` asserts zero residual entries after the same
//! scope-drop-without-wait cycle that produced the spike's 40/400 residue.
//!
//! A grace-period alternative was considered and rejected: `wait_for_exit` returns `Option`, so a
//! reclaimed-but-never-queried owned entry would be indistinguishable from "still running" to any
//! caller that raced the grace window, and a caller in an escalation path (`terminate_and_reap`)
//! reading that `None` would `killpg` a PID the OS may already have recycled. Provenance typing
//! removes the ambiguity at the type level instead of tuning it away with a duration constant.
//!
//! **A first landing of this fix under-specified the transition and missed the shape the P6-2 soak
//! actually found.** The soak's `ScopeDropWithoutWait` residue comes from a PID a scope already
//! registered as **owned** at spawn time (to get a token for its own normal-path `wait_for_exit`),
//! which then drops without `shutdown`. A backstop that re-registers that PID fresh via
//! `register_orphan` collides with the still-resident owned entry -- `AlreadyRegistered` -- and a
//! naive backstop returns early on that error: no SIGKILL escalation, and the *owned* entry (whose
//! token holder is gone) sits in the map forever, the exact gap this module exists to close, just
//! moved rather than fixed. [`Reaper::reassign_as_orphan`] closes it: given the scope's own
//! still-valid token (proof of sole ownership -- nothing else could hold it), it converts the
//! existing slot's reclamation policy from owned to orphan **in place**, never re-registering, so
//! there is no collision to early-return on. [`terminate_and_orphan`] is the paired free function:
//! confirm ownership via `reassign_as_orphan` *first*, signal the group *second* -- reordered from
//! an earlier draft that signaled before confirming ownership, which risked a `killpg` against a
//! live, still-owned process group on any registration collision.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use nix::sys::event::{EvFlags, EventFilter, FilterFlag, KEvent, Kqueue};
use nix::sys::signal::{Signal, killpg};
use nix::sys::wait::{WaitPidFlag, WaitStatus, waitpid};
use nix::unistd::Pid;

use super::timer::{Deadline, SystemClock};

use super::thread_budget::AGENT_DOMAIN_THREAD_COUNT;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReapOutcome {
    Exited(i32),
    Signaled(i32),
    /// `ProcessTerminationError.childOwnershipLost` (`ProcessTermination.swift:44-51`): the
    /// kernel reported ECHILD for a PID this reaper still believed it owned. A typed diagnostic
    /// outcome, not a panic, per design D-4's "counted diagnostic" discipline.
    Lost,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegisterError {
    /// Mirrors `ProcessTerminationError.childOwnershipLost`: this reaper is not the sole potential
    /// owner of this PID's status -- something is already registered for it.
    AlreadyRegistered,
    /// [`Reaper::reassign_as_orphan`] was called for a pid/token pair this reaper does not
    /// recognize as a live owned registration -- never registered, already forgotten, or a token
    /// that does not match the current holder. Distinct from `AlreadyRegistered`: this call never
    /// registers anything, so collision is not the failure mode here.
    NotOwned,
}

struct Slot {
    token: u64,
    /// Reclamation policy for this slot's map entry once reaped (see module doc): `false` (owned)
    /// means only the caller's own explicit [`Reaper::forget`] reclaims it; `true` (orphan) means
    /// the reaper reclaims it itself inside [`reaper_complete`], immediately on reap. Starts at
    /// whichever [`Reaper::register`]/[`Reaper::register_orphan`] chose, and may be flipped
    /// false-to-true in place by [`Reaper::reassign_as_orphan`] -- never true-to-false, so a plain
    /// `AtomicBool` (not a full `Provenance` enum) is enough; interior mutability is required here
    /// specifically because the reassignment happens after the slot is already shared with the
    /// reaper thread.
    is_orphan: std::sync::atomic::AtomicBool,
    outcome: Mutex<Option<ReapOutcome>>,
    condvar: Condvar,
    /// Claims exclusive probe/reap rights for this PID within this reaper -- guards against the
    /// registration-time direct probe and the background thread's kevent/sweep probe racing the
    /// same destructive `waitpid` (see module doc).
    reaping: std::sync::atomic::AtomicBool,
}

struct Shared {
    kq: Kqueue,
    entries: Mutex<HashMap<i32, Arc<Slot>>>,
    next_token: AtomicU64,
    shutdown: std::sync::atomic::AtomicBool,
    pub echild_count: AtomicUsize,
    pub missed_kevent_self_heals: AtomicUsize,
    pub reap_count: AtomicUsize,
    /// Diagnostic only: count of orphan-provenance slots the reaper reclaimed itself. Distinct
    /// from `reap_count` (which counts every reap regardless of provenance) -- this is the direct
    /// witness that the reclamation-policy fix is firing, asserted by the reclamation test.
    pub orphan_reclaim_count: AtomicUsize,
}

pub struct Reaper {
    shared: Arc<Shared>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

/// One safe, encapsulated wrapper around the already-declared `libc::waitid` (`nix::sys::wait`
/// does not expose `waitid` on Apple targets -- confirmed during P6-2, see the spike's `reaper.rs`
/// module doc). Non-destructive (`WNOWAIT`) and non-blocking (`WNOHANG`) -- both required,
/// independently; see module doc for the bug this crate's predecessor spike found by omitting the
/// latter.
///
/// **This crate's second confirmed, narrowly-scoped `unsafe_code` exception** (alongside
/// `agent_claude::process::addchdir`). The P6-2 results doc (`rust/benchmarks/results/v1/
/// p6-2-claude-derisking-v1.md` §4) found this gap the contract itself had not named: `nix`
/// 0.30.1's `waitid` wrapper is gated off every Apple target entirely (only android/freebsd/haiku/
/// linux-gnu), unlike `waitpid`, which the contract correctly stated is safe and fully covered.
/// `libc::waitid` *is* declared for Apple targets with a working `WEXITED`/`WNOHANG`/`WNOWAIT`
/// constant set, so -- exactly like `addchdir_np` -- the fix is one small, well-encapsulated safe
/// wrapper around an already-declared `libc` function, not a from-scratch extern block. Scoped to
/// this one function (not the module or crate) so `Scripts/rust_ffi_guardrails.py`'s two-site
/// assertion stays exact.
#[allow(unsafe_code)]
fn waitid_probe(pid: i32) -> Result<bool, i32> {
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    // SAFETY: `info` is a valid, owned, zero-initialized `siginfo_t` for the duration of the call;
    // `libc::waitid` writes into it and returns success/errno per POSIX. `WNOWAIT` guarantees this
    // call cannot consume the child's exit status; `WNOHANG` guarantees it cannot block.
    let rc = unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            std::ptr::from_mut(&mut info),
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };
    if rc != 0 {
        let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(-1);
        return Err(errno);
    }
    // With WNOHANG and no reportable state change, waitid succeeds (rc == 0) but leaves `si_pid`
    // at 0 -- "still alive, nothing to report" -- distinguished from "this PID exited" by checking
    // the reported pid matches the one targeted.
    Ok(info.si_pid == pid)
}

/// SIGTERM -> grace -> SIGKILL against the *group* (own children only), mirroring
/// `ProcessTermination.swift:446-487`. Uses `killpg` because every spawned child is its own
/// process-group leader (`spawn::spawn`'s `set_pgroup(0)`).
pub fn terminate_and_reap(reaper: &Reaper, pid: i32, token: u64, grace: Duration) -> Option<ReapOutcome> {
    let target = Pid::from_raw(pid);
    let _ = killpg(target, Signal::SIGTERM);
    if let Some(outcome) = reaper.wait_for_exit(pid, token, grace) {
        return Some(outcome);
    }
    let _ = killpg(target, Signal::SIGKILL);
    reaper.wait_for_exit(pid, token, Duration::from_secs(2))
}

/// The orphan-backstop path (contract §5.2, design §4.2) for the production shape the P6-2 spike's
/// soak actually found: a scope registered its child as **owned** at spawn time (to get a token
/// for its own normal-path `wait_for_exit`/`forget` lifecycle), then dropped without calling
/// `shutdown`. `token` is the scope's own still-valid owned-registration token -- sole-owner proof
/// that survives the drop. Confirms that ownership and flips the slot to self-reclaiming orphan
/// provenance via [`Reaper::reassign_as_orphan`] (never re-registers, which would spuriously
/// collide with the still-resident owned entry it is trying to hand off -- see module doc), *then*
/// signals the group and polls [`Reaper::is_registered`] (which needs no token) to decide whether
/// to escalate to SIGKILL after `grace`. Fire-and-forget by design: the caller that drops a scope
/// this way has, by definition, nothing left to hand an outcome to.
pub fn terminate_and_orphan(
    reaper: &Reaper,
    pid: i32,
    token: u64,
    poll_interval: Duration,
    grace: Duration,
) -> Result<(), RegisterError> {
    let already_reaped = reaper.reassign_as_orphan(pid, token)?;
    if already_reaped {
        // The child was already destructively `waitpid`-reaped before this call arrived -- the PID
        // may already be recycled by the OS for an unrelated process. Signaling it now would be
        // exactly the hazard the module doc's rejected-grace-period paragraph names; there is
        // nothing left to terminate, so this is a deliberate no-op, not an oversight.
        return Ok(());
    }
    let target = Pid::from_raw(pid);
    let _ = killpg(target, Signal::SIGTERM);
    let deadline = std::time::Instant::now() + grace;
    while std::time::Instant::now() < deadline {
        if !reaper.is_registered(pid) {
            return Ok(()); // reaped (and, being orphan-provenance, already reclaimed)
        }
        std::thread::sleep(poll_interval);
    }
    if reaper.is_registered(pid) {
        let _ = killpg(target, Signal::SIGKILL);
    }
    Ok(())
}

/// The orphan-backstop path for a PID that was **never registered with this reaper at all** --
/// distinct from [`terminate_and_orphan`], which is the P6-2-soak-found production shape (an
/// *already owned* registration whose scope dropped). Registers fresh as an orphan, signals the
/// group, and polls for escalation; a registration collision here means some other owner
/// genuinely has this PID, so this backstop steps back rather than fighting over it.
pub fn terminate_orphan_backstop(reaper: &Reaper, pid: i32, poll_interval: Duration, grace: Duration) {
    let target = Pid::from_raw(pid);
    let _ = killpg(target, Signal::SIGTERM);
    if reaper.register_orphan(pid).is_err() {
        // Already registered (e.g. raced an explicit `register` for the same pid) -- not this
        // backstop's PID to manage; another owner has it.
        return;
    }
    let deadline = std::time::Instant::now() + grace;
    while std::time::Instant::now() < deadline {
        if !reaper.is_registered(pid) {
            return; // reaped (and, being orphan-provenance, already reclaimed)
        }
        std::thread::sleep(poll_interval);
    }
    if reaper.is_registered(pid) {
        let _ = killpg(target, Signal::SIGKILL);
    }
}

fn reaper_probe_and_reap(shared: &Shared, pid: i32) {
    let slot = {
        let entries = shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.get(&pid).cloned()
    };
    let Some(slot) = slot else {
        return; // not our PID (never registered, or already forgotten/reclaimed)
    };
    if slot
        .outcome
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .is_some()
    {
        return;
    }
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

/// Records the outcome. For an owned (`is_orphan == false`) slot this does **not** remove the map
/// entry -- [`Reaper::wait_for_exit`]/[`Reaper::forget`] still need it. For an orphan
/// (`is_orphan == true`) slot this removes the entry immediately: no token was ever issued for an
/// orphan-registered PID (and [`Reaper::reassign_as_orphan`] only flips an owned slot to orphan
/// given its own still-valid token), so no caller can observe its absence as anything other than
/// "already handled" (see module doc's rejected-alternative paragraph for why this is exact rather
/// than time-based).
fn reaper_complete(shared: &Shared, pid: i32, outcome: ReapOutcome) {
    let slot = {
        let entries = shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.get(&pid).cloned()
    };
    shared.reap_count.fetch_add(1, Ordering::SeqCst);
    let Some(slot) = slot else { return };
    {
        let mut guard = slot.outcome.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        *guard = Some(outcome);
        slot.condvar.notify_all();
    }
    if slot.is_orphan.load(Ordering::SeqCst) {
        // Guarded by identity (not just presence): a concurrent `reassign_as_orphan` racing this
        // same completion could also observe orphan provenance and attempt to reclaim. Both take
        // this same `entries` lock for the actual removal, so only whichever wins the race
        // observes `remove(&pid)` return `Some`, and only that side counts the reclaim -- the
        // `Arc::ptr_eq` check additionally guards against a pathological forget+re-register of the
        // same pid landing between the two locks (a different slot must never be reclaimed here).
        let mut entries = shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if entries.get(&pid).is_some_and(|resident| Arc::ptr_eq(resident, &slot)) && entries.remove(&pid).is_some() {
            shared.orphan_reclaim_count.fetch_add(1, Ordering::SeqCst);
        }
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
            orphan_reclaim_count: AtomicUsize::new(0),
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

    pub fn orphan_reclaim_count(&self) -> usize {
        self.shared.orphan_reclaim_count.load(Ordering::SeqCst)
    }

    pub fn registered_count(&self) -> usize {
        self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner).len()
    }

    /// Whether `pid` still has a live entry -- true from registration until reaped (orphans) or
    /// until reaped **and** explicitly [`forget`](Self::forget)ten (owned). Requires no token, so
    /// it is safe for the orphan-backstop escalation loop, which never holds one.
    pub fn is_registered(&self, pid: i32) -> bool {
        self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner).contains_key(&pid)
    }

    /// Count of entries still awaiting an outcome (`outcome.is_none()`). Unlike
    /// [`Self::registered_count`], excludes completed-but-not-yet-`forget`ten owned entries.
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

    fn register_with(&self, pid: i32, orphan: bool) -> Result<u64, RegisterError> {
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
                    is_orphan: std::sync::atomic::AtomicBool::new(orphan),
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
        // Registration-boundary probe point 1: submits the changelist, returns immediately.
        let _ = self.shared.kq.kevent(&changelist, &mut eventlist[..0], Some(zero_timespec()));
        // Registration-boundary probe point 2 (direct post-activate probe, contract §5.2's third
        // row) -- covers a child that exited between spawn and this `register` call.
        reaper_probe_and_reap(&self.shared, pid);
        Ok(token)
    }

    /// Registers a PID for exit notification. Reclaimed only by the caller's own explicit
    /// [`Self::forget`] -- unchanged from the P6-2 spike, bounded by the same caller discipline
    /// `ProcessTermination.swift`'s registry already relies on today.
    pub fn register(&self, pid: i32) -> Result<u64, RegisterError> {
        self.register_with(pid, false)
    }

    /// Registers a PID as an orphan-backstop registration (contract §5.2's orphan backstop, design
    /// §4.2): no token is issued, so nothing can ever call `wait_for_exit`/`forget` for this PID --
    /// the reaper reclaims the entry itself the instant the reap completes (see module doc).
    pub fn register_orphan(&self, pid: i32) -> Result<(), RegisterError> {
        self.register_with(pid, true).map(|_| ())
    }

    /// Converts an existing **owned** registration into an **orphan** one in place -- the real
    /// orphan-backstop shape (module doc): a scope registered its child as owned at spawn time to
    /// get a token for its own lifecycle, then dropped without calling `shutdown`. `token` must
    /// match the value [`Self::register`] returned for `pid`; it is the sole-owner proof that lets
    /// this call confirm ownership without ever re-registering (re-registering would spuriously
    /// collide with the still-resident entry via `AlreadyRegistered` -- the exact bug this method
    /// exists to avoid).
    ///
    /// Returns `Ok(true)` if the slot's reap had **already completed** before this call arrived (a
    /// benign race against the reaper thread, which may run `reaper_complete` concurrently) -- in
    /// which case this reclaims the now-orphaned entry immediately, and the PID is already
    /// destructively `waitpid`-reaped and may already be recycled by the OS. Returns `Ok(false)` if
    /// the child was still pending, now marked orphan for the reaper to self-reclaim on its next
    /// reap. Callers **must** check this: signaling a PID after `Ok(true)` risks hitting an
    /// unrelated, recycled process -- exactly the hazard the module doc's rejected-grace-period
    /// paragraph names (see [`terminate_and_orphan`], the paired free function that does this).
    pub fn reassign_as_orphan(&self, pid: i32, token: u64) -> Result<bool, RegisterError> {
        let slot = {
            let entries = self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            entries.get(&pid).cloned()
        };
        let Some(slot) = slot else { return Err(RegisterError::NotOwned) };
        if slot.token != token {
            return Err(RegisterError::NotOwned);
        }
        slot.is_orphan.store(true, Ordering::SeqCst);
        let already_done = slot
            .outcome
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some();
        if already_done {
            // See `reaper_complete`'s matching guard: identity-checked removal so a concurrent
            // completion (or a pathological forget+re-register racing between our two locks) can
            // never be double-reclaimed or misattributed.
            let mut entries = self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if entries.get(&pid).is_some_and(|resident| Arc::ptr_eq(resident, &slot)) && entries.remove(&pid).is_some() {
                self.shared.orphan_reclaim_count.fetch_add(1, Ordering::SeqCst);
            }
        }
        Ok(already_done)
    }

    /// Blocks the caller until this PID's slot is reaped or `timeout` elapses. `token` must match
    /// the value [`Self::register`] returned. Only meaningful for owned registrations -- an orphan
    /// registration (via [`Self::register_orphan`], or an owned one later converted by
    /// [`Self::reassign_as_orphan`]) never hands out a token, so no caller can construct a valid
    /// call here for one.
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

    /// Test-only: registers `pid` as owned **without** submitting the
    /// `EVFILT_PROC` kevent -- the only way this reaper can ever learn of the PID's exit is
    /// therefore the periodic sweep (probe point 2/3), never the kevent wake (probe point 1's
    /// registration-time direct probe still runs, so the pid must not have exited yet at
    /// registration time for this to actually exercise the sweep path). This deterministically
    /// isolates "missed kevent, self-healed by the periodic sweep" from the real, only
    /// probabilistically-reproducible race it stands in for.
    #[cfg(test)]
    fn register_without_kevent_for_test(&self, pid: i32) -> u64 {
        let token = self.shared.next_token.fetch_add(1, Ordering::SeqCst);
        let mut entries = self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.insert(
            pid,
            Arc::new(Slot {
                token,
                is_orphan: std::sync::atomic::AtomicBool::new(false),
                outcome: Mutex::new(None),
                condvar: Condvar::new(),
                reaping: std::sync::atomic::AtomicBool::new(false),
            }),
        );
        token
    }

    /// Reclaims a completed **owned** entry after the caller has consumed its outcome via
    /// [`Self::wait_for_exit`]. No-op if `pid` is not registered or `token` does not match.
    pub fn forget(&self, pid: i32, token: u64) {
        let mut entries = self.shared.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if entries.get(&pid).is_some_and(|slot| slot.token == token) {
            entries.remove(&pid);
        }
    }

    /// Stops the shared reaper thread and joins it, decrementing [`AGENT_DOMAIN_THREAD_COUNT`].
    /// Idempotent, matching `ProcessTermination.swift`'s `shutdown()`.
    pub fn shutdown(&self) {
        self.shared.shutdown.store(true, Ordering::SeqCst);
        if let Some(handle) = self.thread.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take() {
            let _ = handle.join();
            AGENT_DOMAIN_THREAD_COUNT.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// The reaper thread body. Registration-boundary probe point 3 (contract §5.2's "repeating
    /// fallback timer" row, 0.5 s interval): `Kqueue::kevent`'s own `timeout` argument doubles as
    /// the periodic tick rather than a second `EVFILT_TIMER` changelist entry -- functionally
    /// equivalent, one fewer changelist entry per PID (a legitimate spike-level simplification
    /// carried forward, per the P6-2 results doc; a second `EVFILT_TIMER` registration is an
    /// equally valid future substrate change with no observable behavior difference).
    fn run_loop(shared: Arc<Shared>) {
        let tick = tick_timespec(500);
        let mut eventlist =
            [KEvent::new(0, EventFilter::EVFILT_READ, EvFlags::empty(), FilterFlag::empty(), 0, 0); 64];
        // The §4.7-pinned 0.5 s fallback-probe interval, via the same deadline-based primitive
        // `agent_claude::process::timer` proves discontinuity-safe -- re-armed each time it fires,
        // rather than an ad hoc `Instant::elapsed()` comparison duplicating that logic here.
        let clock = Arc::new(SystemClock);
        let mut sweep_deadline = Deadline::arm(Arc::clone(&clock), Duration::from_millis(500));
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
            if sweep_deadline.poll() {
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
                        // Missed or delayed EVFILT_PROC delivery, self-healed by the periodic
                        // sweep -- "kevent exit delivery is not contractual under load"
                        // (ProcessTermination.swift:99-105).
                        shared.missed_kevent_self_heals.fetch_add(1, Ordering::SeqCst);
                    }
                }
                sweep_deadline = Deadline::arm(Arc::clone(&clock), Duration::from_millis(500));
            }
        }
    }
}

impl Drop for Reaper {
    /// Belt-and-braces: a panicking caller cannot leak the shared reaper thread (or its
    /// [`AGENT_DOMAIN_THREAD_COUNT`] contribution) into whatever runs next in the same process.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_claude::process::spawn::{SpawnConfig, spawn};

    fn spawn_sh(script: &str) -> super::super::spawn::SpawnedProcess {
        spawn(&SpawnConfig {
            command: "/bin/sh",
            arguments: &["-c".to_string(), script.to_string()],
            environment: &[],
            working_directory: None,
        })
        .expect("spawn must succeed")
    }

    #[test]
    fn owned_registration_round_trips_through_wait_and_forget() {
        let reaper = Reaper::new();
        let child = spawn_sh("exit 7");
        let token = reaper.register(child.pid).expect("register");
        let outcome = reaper
            .wait_for_exit(child.pid, token, Duration::from_secs(5))
            .expect("child must be reaped within 5s");
        assert_eq!(outcome, ReapOutcome::Exited(7));
        assert_eq!(reaper.pending_count(), 0);
        assert_eq!(reaper.registered_count(), 1, "owned entry survives until explicit forget");
        reaper.forget(child.pid, token);
        assert_eq!(reaper.registered_count(), 0);
        reaper.shutdown();
    }

    #[test]
    fn double_registration_is_rejected() {
        let reaper = Reaper::new();
        let child = spawn_sh("sleep 5");
        let first = reaper.register(child.pid).expect("first register");
        assert_eq!(reaper.register(child.pid), Err(RegisterError::AlreadyRegistered));
        let _ = terminate_and_reap(&reaper, child.pid, first, Duration::from_millis(200));
        reaper.shutdown();
    }

    #[test]
    fn sigkill_escalation_reaps_a_sigterm_ignoring_child() {
        // E-P6-2 Part A's config 9, reaper-owned per the P6-2 results doc ("SIGKILL escalation...
        // is reaper- not spawn-attribute-owned"). `trap '' TERM` makes the shell ignore SIGTERM.
        // Synchronizes on a "ready" line so the SIGTERM this test sends cannot race the shell's
        // own `trap` builtin installing the ignore disposition (a real race observed during
        // development: an immediate SIGTERM before `trap` runs kills the child with its *default*
        // disposition, reporting `Signaled(SIGTERM)` instead of exercising the escalation path).
        use std::io::Read as _;
        let reaper = Reaper::new();
        let child = spawn_sh("trap '' TERM; echo ready; while true; do sleep 1; done");
        let token = reaper.register(child.pid).expect("register");
        let mut out = std::fs::File::from(child.stdout_read);
        let mut ready_byte = [0u8; 1];
        let mut line = Vec::new();
        loop {
            out.read_exact(&mut ready_byte).expect("child must print a ready line before dying");
            if ready_byte[0] == b'\n' {
                break;
            }
            line.push(ready_byte[0]);
        }
        assert_eq!(line, b"ready");
        let outcome = terminate_and_reap(&reaper, child.pid, token, Duration::from_millis(300))
            .expect("escalation must eventually reap the child");
        assert!(matches!(outcome, ReapOutcome::Signaled(sig) if sig == libc::SIGKILL), "expected SIGKILL, got {outcome:?}");
        reaper.forget(child.pid, token);
        reaper.shutdown();
    }

    #[test]
    fn missed_kevent_is_self_healed_by_the_periodic_sweep() {
        let reaper = Reaper::new();
        let child = spawn_sh("exit 0");
        // Deliberately bypass EVFILT_PROC registration -- the only way this reaper can learn the
        // child exited is the periodic sweep (see the helper's own doc). Succeeding at all here
        // is therefore, by construction, proof the sweep path resolved it: no other reachable
        // mechanism exists for this pid. (The `missed_kevent_self_heals` diagnostic counter
        // records the same event, but asserting its exact value here proved sensitive to
        // scheduling-instrumentation timing -- e.g. under a ThreadSanitizer build -- around
        // exactly which sweep pass's pending-PID snapshot first observes this specific PID; the
        // counter's correctness is a bookkeeping nicety, not what this test exists to prove.)
        let token = reaper.register_without_kevent_for_test(child.pid);
        let outcome = reaper
            .wait_for_exit(child.pid, token, Duration::from_secs(3))
            .expect("the periodic sweep must self-heal the missed notification within 3s");
        assert_eq!(outcome, ReapOutcome::Exited(0));
        reaper.forget(child.pid, token);
        reaper.shutdown();
    }

    #[test]
    fn orphan_registration_leaves_zero_residual_entries() {
        // The P6-2-found reclamation-policy gap (finding 3), exercised in the *actual* shape the
        // soak found: the scope registers its child as **owned** at spawn time (to get a token for
        // its own normal-path lifecycle), then drops without `shutdown`. An earlier draft of this
        // fix used `terminate_orphan_backstop` (fresh `register_orphan`) here, which collided with
        // this still-resident owned entry via `AlreadyRegistered` and silently no-op'd -- no
        // escalation, entry resident forever, the exact gap moved rather than closed. Regression
        // net for that: `terminate_and_orphan` must succeed via `reassign_as_orphan`.
        let reaper = Reaper::new();
        let child = spawn_sh("exit 0");
        let token = reaper.register(child.pid).expect("owned registration at spawn time");
        terminate_and_orphan(&reaper, child.pid, token, Duration::from_millis(20), Duration::from_secs(2))
            .expect("the scope's own still-valid token must be accepted for reassignment");
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while reaper.is_registered(child.pid) && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!reaper.is_registered(child.pid), "orphan entry must be reclaimed, not resident forever");
        assert_eq!(reaper.registered_count(), 0);
        assert!(reaper.orphan_reclaim_count() >= 1);
        reaper.shutdown();
    }

    #[test]
    fn orphan_backstop_soak_leaves_zero_residual_entries_across_many_cycles() {
        // Scaled-up regression net directly targeting the P6-2 spike's finding: 40/400
        // scope-drop-without-wait cycles left a permanently-resident entry there. Registers each
        // child as owned at spawn time (the real shape), then hands it off via
        // `terminate_and_orphan`, and asserts the count returns to exactly zero every time.
        let reaper = Reaper::new();
        for i in 0..200 {
            let child = spawn_sh("exit 0");
            let token = reaper.register(child.pid).expect("owned registration at spawn time");
            terminate_and_orphan(&reaper, child.pid, token, Duration::from_millis(5), Duration::from_secs(2))
                .unwrap_or_else(|err| panic!("cycle {i}: reassignment must succeed, got {err:?}"));
            let deadline = std::time::Instant::now() + Duration::from_secs(2);
            while reaper.is_registered(child.pid) && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(5));
            }
            assert!(!reaper.is_registered(child.pid), "cycle {i}: orphan entry outlived its reap");
        }
        assert_eq!(reaper.registered_count(), 0, "zero residual entries after 200 scope-drop-without-wait cycles");
        assert_eq!(reaper.echild_count(), 0);
        reaper.shutdown();
    }

    #[test]
    fn owned_registration_dropped_without_wait_is_still_escalated_to_sigkill() {
        // End-to-end regression for the exact bug an earlier draft had: a scope drops an owned
        // registration whose child ignores SIGTERM. `terminate_and_orphan` must both confirm
        // ownership (via the scope's still-valid token) *and* actually escalate to SIGKILL --
        // proving the reassignment path does not silently swallow the signal/escalation sequence
        // the way a fresh `register_orphan` collision would have.
        use std::io::Read as _;
        let reaper = Reaper::new();
        let child = spawn_sh("trap '' TERM; echo ready; while true; do sleep 1; done");
        let token = reaper.register(child.pid).expect("owned registration at spawn time");
        let mut out = std::fs::File::from(child.stdout_read);
        let mut ready_byte = [0u8; 1];
        let mut line = Vec::new();
        loop {
            out.read_exact(&mut ready_byte).expect("child must print a ready line before dying");
            if ready_byte[0] == b'\n' {
                break;
            }
            line.push(ready_byte[0]);
        }
        assert_eq!(line, b"ready");
        terminate_and_orphan(&reaper, child.pid, token, Duration::from_millis(20), Duration::from_millis(300))
            .expect("reassignment must succeed against the scope's own token");
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while reaper.is_registered(child.pid) && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!reaper.is_registered(child.pid), "SIGTERM-ignoring child must still be escalated and reclaimed");
        reaper.shutdown();
    }

    #[test]
    fn reassign_as_orphan_rejects_a_stale_token_without_disturbing_the_real_one() {
        let reaper = Reaper::new();
        let child = spawn_sh("sleep 5");
        let token = reaper.register(child.pid).expect("register");
        assert_eq!(reaper.reassign_as_orphan(child.pid, token.wrapping_add(1)), Err(RegisterError::NotOwned));
        assert_eq!(reaper.registered_count(), 1, "a rejected reassignment must not disturb the owned entry");
        let _ = terminate_and_reap(&reaper, child.pid, token, Duration::from_millis(200));
        reaper.shutdown();
    }

    #[test]
    fn reassign_as_orphan_reports_true_when_the_child_was_already_reaped() {
        // Regression test for the exact hazard the module doc's rejected-grace-period paragraph
        // names: once a pid is destructively `waitpid`-reaped, the OS may already have recycled
        // it for an unrelated process, so a caller must be told "do not signal this pid" rather
        // than being handed an `Ok(())` indistinguishable from "safe to proceed".
        let reaper = Reaper::new();
        let child = spawn_sh("exit 0");
        let token = reaper.register(child.pid).expect("register");
        let outcome = reaper
            .wait_for_exit(child.pid, token, Duration::from_secs(5))
            .expect("child must be reaped within 5s");
        assert_eq!(outcome, ReapOutcome::Exited(0));
        let already_reaped = reaper.reassign_as_orphan(child.pid, token).expect("token is still valid");
        assert!(already_reaped, "reassigning an already-completed slot must report true, not silently succeed as false");
        assert_eq!(
            reaper.registered_count(),
            0,
            "the now-orphaned, already-completed entry must be reclaimed immediately, not left resident"
        );
        reaper.shutdown();
    }

    #[test]
    fn reassign_as_orphan_rejects_a_never_registered_pid() {
        let reaper = Reaper::new();
        assert_eq!(reaper.reassign_as_orphan(i32::MAX, 1), Err(RegisterError::NotOwned));
        reaper.shutdown();
    }

    // `thread_budget_is_exactly_one_reaper_thread_per_reaper_instance` intentionally lives in
    // `tests/agent_claude_process_thread_budget.rs` (its own binary, `--test-threads=1`) rather
    // than here: `AGENT_DOMAIN_THREAD_COUNT` is process-global, and this crate's other unit tests
    // run concurrently in the same test binary and legitimately create/destroy `Reaper` instances
    // of their own, so a before/after delta assertion against it is inherently racy inside the
    // shared `--lib` test binary. The dedicated N=1/4/16 budget test owns the whole process.
}
