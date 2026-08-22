//! Process-wide panic forensics ring buffer.
//!
//! `agentry_ffi::panic_guard::PanicGuard::call` catches every unwind at the
//! FFI boundary and discards the payload, surfacing only `InternalPanic` /
//! `RuntimePoisoned` to callers. On its own that makes a production panic
//! undiagnosable after the fact -- this module is what makes it diagnosable
//! again: a custom `std::panic::set_hook`, installed exactly once at runtime
//! startup (see `install_panic_hook`, called from `lifecycle::CoreRuntime::new`
//! -- and, belt-and-suspenders, from the very top of the FFI `CoreRuntime`
//! constructor, since that outer constructor does identity/config work of its
//! own before reaching this crate -- so it is in place before any
//! `PanicGuard`-wrapped export can run), records the thread name,
//! panic message, source `file:line:col`, and a captured backtrace into a
//! small in-process ring buffer. Callers recover the record through
//! `recent_panics()` -- surfaced across FFI as
//! `agentry_ffi::CoreRuntime::panic_forensics()` -- instead of only ever
//! learning "internalPanic".

use std::backtrace::Backtrace;
use std::collections::VecDeque;
use std::panic::PanicHookInfo;
use std::sync::{Mutex, Once};

/// Number of most-recent panics retained. Small and fixed: this is a
/// forensics aid for the next investigation, not an unbounded log.
const CAPACITY: usize = 4;

/// One captured panic, forensic-ready.
#[derive(Clone, Debug)]
pub struct PanicRecord {
    pub thread_name: String,
    pub message: String,
    /// `file:line:col`, when the panic carried a `Location` (it always does
    /// for `panic!`-originated panics on this toolchain).
    pub location: Option<String>,
    pub backtrace: String,
}

impl PanicRecord {
    /// Single forensic string safe to hand to a Swift caller or log line.
    pub fn describe(&self) -> String {
        let location = self.location.as_deref().unwrap_or("<unknown location>");
        format!(
            "thread=\"{}\" at {}: {}\n{}",
            self.thread_name, location, self.message, self.backtrace
        )
    }
}

static RING: Mutex<VecDeque<PanicRecord>> = Mutex::new(VecDeque::new());
static INSTALL: Once = Once::new();

/// Installs the forensic panic hook exactly once per process, chaining to
/// whatever hook was previously registered so default stderr reporting (and
/// any other pre-existing hook) keeps firing unchanged. Idempotent -- safe to
/// call from every `CoreRuntime::new`, which is the guarantee callers rely on
/// to keep this ahead of any `PanicGuard`-wrapped export.
pub fn install_panic_hook() {
    INSTALL.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            record_panic(info);
            previous(info);
        }));
    });
}

fn record_panic(info: &PanicHookInfo<'_>) {
    let record = PanicRecord {
        thread_name: std::thread::current()
            .name()
            .unwrap_or("<unnamed>")
            .to_owned(),
        message: payload_message(info),
        location: info.location().map(|location| {
            format!(
                "{}:{}:{}",
                location.file(),
                location.line(),
                location.column()
            )
        }),
        backtrace: Backtrace::force_capture().to_string(),
    };
    let mut ring = RING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if ring.len() == CAPACITY {
        ring.pop_front();
    }
    ring.push_back(record);
}

fn payload_message(info: &PanicHookInfo<'_>) -> String {
    let payload = info.payload();
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "<non-string panic payload>".to_owned()
    }
}

/// Returns the recorded panics, oldest first, most-recent last. Deliberately
/// does not consult (or care about) any `PanicGuard` poison state: reading
/// this must keep working precisely when the guard has poisoned the runtime,
/// since explaining *why* it poisoned is the entire point.
pub fn recent_panics() -> Vec<PanicRecord> {
    RING.lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .iter()
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Single test, not split across functions: `RING` is process-global and
    // `cargo test` runs test functions concurrently, so two tests both
    // pushing panics into it would race over which entries survive eviction.
    // Keeping every push-then-assert step sequential in one thread avoids
    // that without reaching for external serialization.
    #[test]
    fn hook_records_and_caps_ring_buffer() {
        install_panic_hook();

        let result = std::panic::catch_unwind(|| {
            panic!("panic_forensics ring buffer unit test boom");
        });
        assert!(result.is_err());

        let after = recent_panics();
        let last = after.last().expect("hook should have recorded an entry");
        assert!(
            last.message
                .contains("panic_forensics ring buffer unit test boom")
        );
        assert!(
            last.location
                .as_deref()
                .is_some_and(|loc| loc.contains("panic_forensics.rs"))
        );
        assert!(!last.backtrace.is_empty());
        assert!(!last.describe().is_empty());

        for index in 0..CAPACITY + 2 {
            let _ = std::panic::catch_unwind(|| {
                panic!("panic_forensics capacity test boom #{index}");
            });
        }
        assert!(recent_panics().len() <= CAPACITY);
    }
}
