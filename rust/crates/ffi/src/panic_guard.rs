use crate::errors::CoreError;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};

/// Project-owned panic containment. UniFFI's call-status conversion is not our
/// lifecycle authority, so every exported method enters this guard first.
pub(crate) struct PanicGuard {
    poisoned: AtomicBool,
}

impl PanicGuard {
    pub(crate) const fn new() -> Self {
        Self {
            poisoned: AtomicBool::new(false),
        }
    }

    pub(crate) fn call<T>(
        &self,
        operation: impl FnOnce() -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        if self.poisoned.load(Ordering::Acquire) {
            return Err(CoreError::RuntimePoisoned);
        }
        match catch_unwind(AssertUnwindSafe(operation)) {
            Ok(result) => result,
            Err(_) => {
                self.poisoned.store(true, Ordering::Release);
                Err(CoreError::InternalPanic)
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn is_poisoned(&self) -> bool {
        self.poisoned.load(Ordering::Acquire)
    }
}
