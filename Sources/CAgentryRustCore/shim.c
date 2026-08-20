#if !__has_include("AgentryRustArchiveReady.h")
#error "Missing Agentry Rust FFI archive. Run `make dev-cargo-archive PROFILE=debug` (or PROFILE=release) before building AgentryCoreBridge."
#endif

#include "AgentryRustArchiveReady.h"
#include "AgentryCoreFFI.h"

#if AGENTRY_RUST_ARCHIVE_ABI_EPOCH != 1
#error "Stale Agentry Rust FFI archive ABI. Regenerate it with `make dev-cargo-archive PROFILE=debug` (or PROFILE=release)."
#endif

// SwiftPM requires a C-family source for this ordinary Clang/link target.
// The generated UniFFI declarations and the staged static archive own all ABI.
void agentry_rust_core_link_anchor(void) {}
