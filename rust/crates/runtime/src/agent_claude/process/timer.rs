//! P6-4 (design §4.7, contract §11, charter §11.6): the deadline-based timer primitive the reaper's
//! periodic probe consumes today and the turn state machine (P6-5) will reuse for the 1.0 s
//! idle-fallback and 1.5 s interrupt-ACK deadline -- one scheduling substrate, tested once here,
//! not reimplemented per timer.
//!
//! **What "survives a simulated sleep-length clock discontinuity" means, precisely, and what it
//! does not.** This crate cannot suspend the OS inside a `cargo test`, so "simulated" means: the
//! clock this primitive reads is injectable ([`Clock`]), and the test jumps a fake clock forward
//! discontinuously between two polls -- from before a deadline to after it, in one step, with no
//! intermediate wake -- rather than advancing it in small increments. The property under test is
//! that the scheduler is **deadline-based** (`deadline - now()`, recomputed on every wake), not
//! **accumulate-based** (summing slept intervals). A deadline-based scheduler is discontinuity-safe
//! by construction: whatever `now()` reads on the next poll, `now() >= deadline` fires exactly
//! once, never before, never more than once, never silently skipped. This is a robustness property
//! of the scheduling logic, not a claim about which macOS clock source is chosen underneath a real
//! sleep/wake cycle -- that real-hardware parity observation is P6-8's soak, named there
//! ("≥1 sleep/wake cycle across a live turn"), not re-claimed here.
//!
//! Three named cases parameterize the one primitive per the design's three pinned timers: the
//! reaper's 0.5 s fallback probe (consumed today, [`super::reaper`]), the 1.0 s idle fallback and
//! 1.5 s interrupt-ACK deadline (both P6-5 consumers of this same primitive, tested here ahead of
//! that wiring so the scheduling substrate itself is proven once).

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// An injectable source of monotonic time. The production implementation wraps
/// [`std::time::Instant`]; tests substitute [`FakeClock`] to model a discontinuous jump.
pub trait Clock: Send + Sync {
    fn now(&self) -> Instant;
}

#[derive(Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// A clock whose value is set explicitly rather than advancing with wall-clock time -- lets a
/// test model "the underlying clock jumped forward by an arbitrary amount between two reads" in
/// one step, which is the structural stand-in for a sleep-length discontinuity (see module doc).
pub struct FakeClock {
    now: Mutex<Instant>,
}

impl FakeClock {
    pub fn new() -> Arc<Self> {
        Arc::new(Self { now: Mutex::new(Instant::now()) })
    }

    /// Jumps the clock forward discontinuously -- no intermediate value is ever observable
    /// between the pre- and post-jump reads, modeling a suspend/resume rather than gradual
    /// wall-clock advance.
    pub fn jump_forward(&self, by: Duration) {
        let mut guard = self.now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        *guard += by;
    }
}

impl Clock for FakeClock {
    fn now(&self) -> Instant {
        *self.now.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// A single deadline, recomputed against `clock.now()` on every poll -- never accumulated from
/// slept durations. `poll()` returns `true` at most once (the first poll at or after the
/// deadline); every poll before or after that one returns `false`.
pub struct Deadline<C: Clock> {
    clock: Arc<C>,
    at: Instant,
    fired: bool,
}

impl<C: Clock> Deadline<C> {
    pub fn arm(clock: Arc<C>, after: Duration) -> Self {
        let at = clock.now() + after;
        Self { clock, at, fired: false }
    }

    /// Returns `true` exactly once, the first time this is called with `clock.now() >= at`.
    pub fn poll(&mut self) -> bool {
        if self.fired {
            return false;
        }
        if self.clock.now() >= self.at {
            self.fired = true;
            return true;
        }
        false
    }

    pub fn has_fired(&self) -> bool {
        self.fired
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The §4.7 timer test, parameterized over the design's three pinned durations (reaper probe
    /// 0.5 s, idle fallback 1.0 s, interrupt-ACK deadline 1.5 s): arm a deadline, poll before the
    /// jump (must not fire), jump the fake clock discontinuously past the deadline in one step,
    /// poll again (must fire exactly once), poll a third time (must not fire again).
    fn assert_survives_discontinuity(duration: Duration) {
        let clock = FakeClock::new();
        let mut deadline = Deadline::arm(Arc::clone(&clock), duration);

        assert!(!deadline.poll(), "must not fire before the deadline ({duration:?})");

        // Simulate a sleep-length discontinuity: jump straight past the deadline in one step,
        // with no intermediate poll -- there is no wall-clock wait here at all, which is the
        // point (see module doc: this exercises the scheduler's deadline-vs-now recomputation,
        // not a real sleep).
        clock.jump_forward(duration + Duration::from_secs(600));

        assert!(deadline.poll(), "must fire on the first poll at/after the deadline ({duration:?}) -- a spurious skip");
        assert!(!deadline.poll(), "must not fire a second time -- a spurious double-fire ({duration:?})");
    }

    #[test]
    fn reaper_fallback_probe_interval_survives_discontinuity() {
        assert_survives_discontinuity(Duration::from_millis(500));
    }

    #[test]
    fn idle_fallback_interval_survives_discontinuity() {
        assert_survives_discontinuity(Duration::from_millis(1000));
    }

    #[test]
    fn interrupt_ack_deadline_survives_discontinuity() {
        assert_survives_discontinuity(Duration::from_millis(1500));
    }

    #[test]
    fn does_not_fire_early_under_ordinary_advance() {
        let clock = FakeClock::new();
        let mut deadline = Deadline::arm(Arc::clone(&clock), Duration::from_millis(500));
        clock.jump_forward(Duration::from_millis(100));
        assert!(!deadline.poll());
        clock.jump_forward(Duration::from_millis(100));
        assert!(!deadline.poll());
    }

    #[test]
    fn system_clock_is_monotonic_across_two_reads() {
        let clock = SystemClock;
        let first = clock.now();
        std::thread::sleep(Duration::from_millis(1));
        let second = clock.now();
        assert!(second >= first);
    }
}
