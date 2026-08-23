//! P6-4 (`docs/architecture/rust-agent-claude-v1.md` §5.1/§5.2/§12, design §4.1): the confirmed,
//! unconditional `unsafe_code` prerequisite this crate carries -- a hand-declared `extern "C"`
//! binding for `posix_spawn_file_actions_addchdir_np`.
//!
//! **Why this exists at all.** `ProcessLauncher.swift:186-196` uses
//! `posix_spawn_file_actions_addchdir_np` to set the spawned child's working directory. `nix`
//! 0.30.1 has no wrapper for it (confirmed by reading `nix-0.30.1/src/spawn.rs` directly -- the
//! crate implements `add_dup2`/`add_open`/`add_close` but nothing chdir-shaped), and `libc` 0.2.189
//! declares the symbol only for `linux-gnu`/`linux-musl`/`cygwin`/`hurd`/`solarish` -- absent from
//! every Apple target (`libc-0.2.189/src/unix/bsd/apple/mod.rs` has no such symbol). The P6-2 spike
//! (`rust/spikes/agent-claude-derisking-spike/src/spawn.rs`) confirmed this gap and deliberately did
//! not implement `chdir`, naming it a P6-4 prerequisite. This module is that prerequisite, landed.
//!
//! **Why the crate's lint posture changed to accommodate it.** `rust/crates/runtime/src/lib.rs`
//! carried `#![forbid(unsafe_code)]`; `forbid` cannot be downgraded by any inner `#[allow(...)]`,
//! anywhere in the crate -- that is its entire purpose, distinct from `deny`. The crate manifest
//! and `lib.rs` were therefore both changed to `deny` (see their own doc comments), and this module
//! and this module carries one of the crate's two `#[allow(unsafe_code)]` sites -- the other is
//! `agent_claude::process::reaper::waitid_probe`, a second Apple-specific `nix` gap found during
//! P6-2 (see that module's doc). `Scripts/rust_ffi_guardrails.py` asserts the crate has exactly
//! these two sites, no more.
//!
//! **Scope discipline.** This module does not reimplement `posix_spawn_file_actions_t` handling.
//! `nix::spawn::PosixSpawnFileActions` already owns the object's lifecycle (`init`/`add_dup2`/
//! `add_close`/`Drop`, see `spawn.rs`); this module only adds the one action `nix` cannot express,
//! via a pointer cast into that same object. `PosixSpawnFileActions` is `#[repr(transparent)]` over
//! `libc::posix_spawn_file_actions_t` (`nix-0.30.1/src/spawn.rs`, verified by direct source read),
//! so a `*mut PosixSpawnFileActions` and a `*mut libc::posix_spawn_file_actions_t` share address
//! and layout -- exactly the same pattern `nix`'s own `add_dup2`/`add_close` use internally
//! (`&mut self.fa as *mut libc::posix_spawn_file_actions_t`), just from outside the type since its
//! field is private. A `debug_assert_eq!` on `size_of` guards the layout assumption so a future
//! `nix` upgrade that broke it would fail loudly in every debug/test build rather than corrupt
//! memory silently.

#![allow(unsafe_code)]

use std::ffi::CStr;
use std::mem::size_of;

use nix::spawn::PosixSpawnFileActions;

unsafe extern "C" {
    /// Darwin libc symbol with no `nix` wrapper (see module doc). Declared exactly as
    /// `<spawn.h>` specifies it: takes the file-actions object by pointer and a NUL-terminated
    /// path, returns `0` on success or a positive `errno` value on failure (POSIX
    /// `posix_spawn_file_actions_add*` convention -- it does **not** set `errno` and return `-1`
    /// the way most libc calls do).
    fn posix_spawn_file_actions_addchdir_np(
        file_actions: *mut libc::posix_spawn_file_actions_t,
        path: *const libc::c_char,
    ) -> libc::c_int;
}

/// Adds a chdir action to `actions`, mirroring `ProcessLauncher.swift:186-196`. `path` must be a
/// NUL-terminated absolute or relative path; the child's cwd is resolved against its own
/// filesystem view at `exec` time, exactly as `posix_spawn_file_actions_addchdir_np` specifies.
///
/// Returns the raw `errno` value on failure (POSIX's `posix_spawn_file_actions_add*` family
/// returns the error code directly rather than setting the global `errno`).
pub fn add_chdir(actions: &mut PosixSpawnFileActions, path: &CStr) -> Result<(), i32> {
    debug_assert_eq!(
        size_of::<PosixSpawnFileActions>(),
        size_of::<libc::posix_spawn_file_actions_t>(),
        "nix::spawn::PosixSpawnFileActions is no longer #[repr(transparent)] over \
         libc::posix_spawn_file_actions_t -- the pointer cast below is unsound; re-verify against \
         the pinned nix version before proceeding",
    );
    // SAFETY: `actions` is a valid, exclusively-borrowed `PosixSpawnFileActions` for the duration
    // of this call (enforced by the `&mut` borrow), and that type is `#[repr(transparent)]` over
    // `libc::posix_spawn_file_actions_t` (verified above at runtime in debug/test builds, and by
    // direct source read of the pinned `nix = "=0.30.1"` at build time) -- so casting its address
    // to `*mut libc::posix_spawn_file_actions_t` is exactly the pointer `nix`'s own `add_dup2`/
    // `add_close` pass to the equivalent libc calls internally. `path` is a valid `CStr` reference
    // whose pointer remains valid for the duration of this call (the callee reads it synchronously
    // and does not retain it past return, per POSIX). This function mutates only the pointed-to
    // file-actions object, matching every other `add_*` action nix itself adds this same way.
    let fa_ptr = std::ptr::from_mut(actions).cast::<libc::posix_spawn_file_actions_t>();
    let rc = unsafe { posix_spawn_file_actions_addchdir_np(fa_ptr, path.as_ptr()) };
    if rc == 0 { Ok(()) } else { Err(rc) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn layout_assumption_holds_for_the_pinned_nix_version() {
        assert_eq!(
            size_of::<PosixSpawnFileActions>(),
            size_of::<libc::posix_spawn_file_actions_t>()
        );
    }

    #[test]
    fn add_chdir_accepts_a_real_directory() {
        let mut actions = PosixSpawnFileActions::init().expect("init");
        let tmp = CString::new(std::env::temp_dir().to_str().expect("utf8 tmp path")).expect("nul");
        add_chdir(&mut actions, &tmp).expect("addchdir_np on an existing directory must succeed");
    }
}
