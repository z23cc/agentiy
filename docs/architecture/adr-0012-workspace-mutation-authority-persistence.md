# ADR-0012: Workspace Mutation Authority and Canonical Persistence — Rust Core Single-Writer, Single-Writer Lease Protocol, and Fail-Closed Fault Isolation

**Status:** Accepted (charter §7.3, §15.3, §16 Phase 5; User ruling 2026-09-03)
**Date:** 2026-09-03
**Decision owner:** User
**Authority baseline:** `docs/spec/rust-workspace-document-projection-v1.md` (P5-0 through P5-15)
**Governing decisions:** Charter §7.3, §15.3, §16 Phase 5; ADR-0001, ADR-0003, ADR-0006, ADR-0008, ADR-0011 (P8)

---

## Context

### Historical Dual-Writer Divergence (P5-0 through P5-4e)

During early Phase 5 implementation slices, workspace domain responsibilities were divided across an asymmetric language and runtime boundary:

1. **Rust Core Domain Runtime (`agentry-runtime`)**: Implemented pure document projection (`project_workspace_document_v1` in `workspace_context.rs`), transaction state machines, and journal codecs (`workspace_persistence_journal.rs`).
2. **Swift Domain Runtime (`RepoPromptDomainRuntime`)**: Retained ownership of physical file I/O, storage directories, macOS kernel file locking (`DomainWorkspaceAuthorityLease.swift`), and catalog serialization (`DomainPersistenceCoordinator` in `DomainPersistence.swift`).

This created a distributed two-phase directive dance across the UniFFI boundary. To execute a mutation (such as `createWorkspace` or `saveWorkspace`), Rust planned the operation and yielded discrete step directives (`writePendingJournal`, `publishWorkspaceDocument`, `writeCommittedJournal`, `writeSavedRevision`, `publishCatalog`) across FFI. Swift received each directive, executed physical POSIX disk I/O, and invoked `transaction.report(.success(...))` back into Rust.

This split authority suffered from fundamental structural liabilities:

- **Dual Catalog & Journal Representations**: Swift maintained `RuntimeWorkspaceCatalog: Codable` and `DomainWorkingJournal: Codable`, while Rust maintained `WorkspaceProjectionCatalog` and `WorkspaceRecordedOperationV1`, creating permanent serialization drift risks.
- **Split Transaction Integrity**: If an I/O error or crash occurred midway through Swift's directive loop, transaction recovery depended on partial state reconciliations across language boundaries.
- **Unbounded Cross-FFI Roundtrips**: A single workspace creation required up to 6 synchronous FFI calls to step through intermediate directives.
- **Lock Inversion Hazards**: Swift acquired file locks (`workspace-catalog.lock`, `workspace-<id>.lock`) while holding actor isolation on `DomainWorkspaceContextAuthority`, while Rust maintained internal mutexes (`WorkspaceCommandAdmissionInnerV1`).

### The 2026-09-01 Catastrophic Incident & Root Cause Analysis

On 2026-09-01, an operational disaster occurred (`docs/investigations/workspace-authority-fix-20260901.md`): Agent Mode failed across all MCP sessions with `workspace_removed`, workspace switching failed in CLI smoke tests, and 5,732 empty shell directories accumulated on disk.

Forensic examination revealed a four-stage cascading failure chain:

1. **Whole-System Recovery Poisoning in Rust**:
   During startup reconciliation, `derive_semantic_full_recovery_v1` (`workspace_persistence_journal.rs:3370–3390`) evaluated journal evidence across all catalog entries. For a single workspace entry, the journal evidence was invalid or untrusted (`authoritative == false`). Line 3389 executed:
   ```rust
   admission_authoritative &= authoritative;
   ```
   A single non-authoritative entry permanently forced `admission_authoritative = false`. Consequently, lines 3432–3438 evaluated:
   ```rust
   let global_health = if admission_authoritative {
       workspace_recovery_health_v1(WorkspaceProjectionHealthKind::Writable, None)
   } else {
       workspace_recovery_health_v1(
           WorkspaceProjectionHealthKind::DegradedReadOnly,
           Some("working_journal_recovery_unavailable".to_owned()),
       )
   };
   ```
   Furthermore, line 3694 called `admission.quarantine_full_recovery(...)`, setting `inner.quarantined = true`, which caused all subsequent command claims and preflights to return `InvalidTransaction`.

2. **Swift Storage Lease Relinquishment**:
   `DomainWorkspaceContextAuthority.swift:1273–1275` checked:
   ```swift
   guard durableCatalog.health.acceptsMutations, commandAdmission != nil else { return false }
   ```
   Because `durableCatalog.health` was `degradedReadOnly`, `reconcileAfterLeaseAcquisition` failed guard #6. In `DomainWorkspaceAuthorityLease.swift:684–688`, Swift transitioned to `.failed` with `failedReason = "canonical_storage_reconciliation_failed"` and called `lease.relinquishForRetry()`. Swift surrendered the kernel `flock` and permanently disabled mutation access.

3. **Permissive Outcome Check in `WorkspaceManagerViewModel`**:
   In `WorkspaceManagerViewModel.swift:4460–4464`:
   ```swift
   private static func isSuccessfulDomainOutcome(_ outcome: DomainCommandOutcome) -> Bool {
       outcome.disposition == .applied
           || outcome.disposition == .unchanged
           || outcome.disposition == .deduplicated
   }
   ```
   When `createWorkspace` was invoked, it first created the physical directory structure via `ensureWorkspaceDirectoryExists(...)` (`Workspace-<name>-<uuid>/` with `_git_data/AgentSessions/Chats`). It then called `domainWorkspaceAuthorityClient.create(...)`. Because domain authority was degraded, Rust returned an unapplied outcome mapped by Swift to `.unchanged` / `.deduplicated`. `isSuccessfulDomainOutcome` evaluated this as `true`.

4. **Silent Data Loss & Shell Directory Proliferation**:
   Because `isSuccessfulDomainOutcome` returned `true`, no error was surfaced to the UI, no exception was thrown, and the workspace was added to the in-memory `workspaces` array. However, `workspace.json` was never written. On application restart, the in-memory array vanished, prompting tests and users to recreate the workspace, spawning 5,732 empty shell directories with no document file. Concurrently, test suites ran without storage sandboxing, writing directly into the developer's live `~/Library/Application Support/Agentry` container.

### Charter Phase 5 Mandate

Charter §16 Phase 5 mandates that Rust become the **sole canonical mutation authority and disk persistence writer** for Agentry workspaces:

- Rust must own all domain facts, document mutation state machines, and direct physical disk writes for `workspace.json`, `workspace-catalog.json`, working journals, and metadata sidecars.
- The intermediate Swift directive loop and shadow catalog persistence in `DomainPersistence.swift` must be completely deleted upon cutover (§15.3 item 10: beta-soak, forward-fix only, no runtime rollback toggles).
- Single-entry catalog or journal corruption must be isolated with strict row-level quarantine: an individual unauthoritative workspace must never degrade global health or poison unrelated workspaces (§7.3, §15.3).

---

## Decision

### 1. Rust as Single Canonical Mutation Authority & Disk Persistence Writer

#### 1.1 Sole Mutation Authority & Storage Responsibility
1. **Single Canonical Writer**: Rust (`agentry-runtime` / `agentry-domain-workspace`) is the sole in-memory mutation authority and the sole entity permitted to perform physical disk writes for:
   - Canonical workspace documents: `workspaces/<workspace-id>/workspace.json`
   - Canonical workspace catalog: `.agentry-domain-runtime/workspace-catalog.json`
   - Working journals: `.agentry-domain-runtime/working-journals/workspace-<workspace-id>.journal`
   - Saved revision sidecars: `.agentry-domain-runtime/revisions/workspace-<workspace-id>.saved-revision`
   - Deletion tombstones: `.agentry-domain-runtime/deletions/workspace-<workspace-id>.deletion`
   - Read projection checkpoints: `.agentry-domain-runtime/workspace-projection/checkpoint-v1.json`
2. **Elimination of Swift Physical Write Loops**:
   - The distributed directive loop across FFI (`WorkspaceCreateDirectiveV1`, `WorkspaceSaveDirectiveV1`, `transaction.nextDirective()`, `transaction.report()`) is completely eliminated.
   - Swift `DomainPersistenceCoordinator` is stripped of all workspace document and catalog write methods (`persistCreatedBlocking`, `persistWorkingBlocking`, `persistSavedBlocking`, `persistExternalReloadBlocking`, `persistConflictRebaseBlocking`, `persistDeletedBlocking`).
   - Swift `DomainWorkspaceContextAuthority` no longer maintains redundant disk mirrors, executes catalog file locks, or encodes disk JSON. It delegates mutations directly to Rust via typed, synchronous UniFFI exports (`CoreRuntime` entry points) and applies returned outcomes directly.

#### 1.2 Transaction State Machine & Operations Pipeline
All workspace mutations are modeled as atomic, two-phase prepared transactions governed by Rust:

1. **Transaction Lifecycle**:
   - **Phase 1: Admission & Claim Reservation**:
     The caller provides a `CommandEnvelope` containing a caller-generated `operation_id` (UUID), `workspace_id`, and expected revision CAS tokens. Rust checks the idempotent replay ledger: if the operation has already committed, Rust returns the cached receipt (`AcquireKind::Replay`). Otherwise, Rust reserves an admission ticket with a unique generation token (`WorkspaceCommandExecutionClaimV1`).
   - **Phase 2: Semantic Preflight & CAS Fencing**:
     Rust validates candidate payloads against hard bounds (max 32 MiB per document, max 64 MiB catalog). Rust verifies that expected revisions match current durable revisions (`expected_working_revision == current_working_revision`, `expected_catalog_revision == current_catalog_revision`). Any mismatch returns `CoreWorkspaceSemanticPreflightDispositionV1::Conflict`.
   - **Phase 3: Direct Atomic Durability Execution**:
     Rust executes the transaction pipeline directly against the filesystem using the POSIX atomic write protocol (`temp + fsync + rename`).
   - **Phase 4: Authority Commit Point & In-Memory Projection Update**:
     The successful atomic rename of the canonical file (`workspace.json` for document saves; `workspace-catalog.json` for creates/deletions) marks the irreversible authority commit point. Rust advances the monotonic `publication_sequence`, updates the in-memory `WorkspaceProjectionCatalog`, and returns a `WorkspaceCommandOutcome::Applied(receipt)`.

2. **The 4 Canonical Transaction Types**:
   - **Create (`createWorkspace`)**:
     Validates candidate document -> creates workspace directory structure -> writes pending journal marker -> writes atomic `workspace.json` -> writes committed journal -> writes saved-revision sidecar -> removes deletion sidecar if present -> commits `workspace-catalog.json` via exact raw-byte CAS rename -> updates projection catalog -> returns `.applied`. If pre-authority failure occurs, Rust cleans up staged files and directory shells.
   - **Save (`saveWorkspace`)**:
     Validates dirty working state against expected revision -> writes pending journal marker (crash recovery proof) -> writes atomic `workspace.json` (authority commit point) -> writes committed journal -> writes saved-revision sidecar -> advances `saved_revision` -> clears dirty flag -> increments publication sequence -> returns `.applied`.
   - **Mutate Working Document / Selection / Context**:
     Applies in-memory delta -> advances `working_revision` or `context_revision` -> appends entry to working journal -> emits publication event -> returns `.applied`. Does not touch `workspace.json` until explicit save.
   - **Delete (`deleteWorkspace`)**:
     Validates workspace existence -> writes deletion tombstone sidecar -> commits `workspace-catalog.json` without the target entry via CAS rename (authority commit point) -> updates projection catalog -> performs best-effort cleanup of workspace directory (non-fatal if cleanup is incomplete) -> returns `.applied`.

3. **8-Transition Working Journal Machine (`working-journal.json`)**:
   The working journal ledger maintains an append-only log bounded to $\le 256$ operations and $\le 7$ days of history across 8 deterministic transitions:
   `seed`, `recoverPending`, `create`, `unchanged`, `working`, `save`, `externalReload`, `conflictRebase`.

#### 1.3 Concurrency Controls & Compare-And-Swap (CAS) Fences
To guarantee absolute consistency without distributed locks:

1. **Revision State Triple**:
   Every workspace document is fenced by `{ workingRevision: u64, savedRevision: u64, dirty: bool }`.
   Contexts within a document are individually fenced by `{ contextID -> workingRevision: u64 }`.
   The global catalog is fenced by monotonic `catalogRevision: u64`.
2. **CAS Invariant**:
   Every mutating command must supply its observed `expected_working_revision` and `expected_catalog_revision`. If the durable state has advanced, Rust rejects the transaction with `Conflict` before any disk I/O occurs.
3. **Exact Raw-Byte Catalog CAS Fence**:
   For catalog mutations, Rust reads `workspace-catalog.json` under kernel lock and computes its raw SHA-256 digest. Rust stages the new catalog in a temporary file and fsyncs. Immediately prior to atomic rename, Rust re-verifies that the on-disk catalog digest matches the initial read. If external modification occurred, the rename is aborted and `Conflict` is returned.

#### 1.4 Atomic POSIX File I/O Protocol (Temp + Fsync + Rename)
All physical writes performed by Rust adhere to POSIX atomic durability semantics:

1. **Same-Filesystem Temporary Staging**:
   Temporary files are created in the exact target directory as `<target_filename>.<uuid>.tmp` to guarantee they reside on the same filesystem mount and APFS volume, ensuring `rename` is an atomic inode pointer swap (preventing `EXDEV`).
2. **File Creation Flags**:
   Opened with `O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC` with strict mode `0600` (read/write by owner only).
3. **Content Flush (`fsync`)**:
   After writing validated canonical bytes, Rust executes `fsync(fd)` (or `fcntl(fd, F_FULLFSYNC)` on macOS) to flush OS page buffers to non-volatile physical storage.
4. **Atomic Rename (`rename`)**:
   Rust invokes `rename(tmp_path, target_path)`. Under POSIX and APFS, this guarantees that concurrent readers either observe the old file or the new file in its entirety, with zero possibility of observing partial, truncated, or zero-byte states.
5. **Parent Directory Flush**:
   Rust opens the parent directory with `O_RDONLY | O_CLOEXEC` and executes `fsync(dir_fd)` to ensure directory metadata changes are durable on disk.
6. **Pre-Authority Rollback**:
   If an I/O error or failure occurs at any step prior to `rename`, Rust unlinks the temporary file and aborts the transaction. For `createWorkspace`, Rust removes the partially staged workspace directory to prevent shell directory leaks.

#### 1.5 Crash Recovery & Idempotency Invariants
1. **Pending-Save Recovery**:
   When opening a workspace with a `.pending-journal` marker:
   - Rust calculates `disk_document_digest = SHA-256(workspace.json)`.
   - If `pending_document_digest == disk_document_digest`: The physical save succeeded before the crash. Rust promotes the working journal to committed status, writes `saved-revision`, and clears the pending marker.
   - If `pending_document_digest != disk_document_digest`: The crash occurred before `workspace.json` was replaced. Rust discards the pending marker and restores the uncommitted working state without data loss.
2. **Idempotent Replay Ledger**:
   Rust maintains a bounded in-memory ledger of recent `(operation_id, request_digest) -> WorkspaceCommandOutcome`. Re-submitted commands return identical receipts without re-executing disk writes or advancing revisions.

---

### 2. Single-Writer Authority Lease Protocol & Headless MCP (P8) Alignment

To guarantee that dual-writer divergence never recurs across application and background CLI topologies, all physical mutation rights over canonical workspace storage are strictly governed by the **Single-Writer Authority Lease Protocol** (aligning ADR-0006, ADR-0011 Addendum P8, and P5-0):

#### 2.1 Storage Scope Identity & Exclusion of Profile / Runtime Roots
1. **Physical Canonical Scope**: The lease scope is strictly bound to the physical canonical `workspaceStorageDirectory`.
   - *Included in Scope:* All workspace catalog files (`workspace-catalog.json`), working journals (`workspace-<id>.journal` / `working-journal.json`), saved revisions (`saved-revision.json`), and document files (`workspace.json`) stored under the canonical root.
   - *Explicitly Excluded from Scope:* The runtime's separate metadata directory (`storageDirectory`), event directory (`eventDirectory`), and the diagnostic `profileIdentifier`. Independent profiles or runtime configurations addressing the same physical workspace directory contend on the same kernel lease.
2. **Deterministic Path Canonicalization**:
   To prevent symlink bypass or path aliasing:
   - Lexically standardize the absolute input path (`standardizedFileURL`).
   - Walk upward to the nearest existing ancestor on the local filesystem.
   - Resolve symlinks on that nearest existing ancestor (`resolvingSymlinksInPath()`).
   - Append any nonexistent descendant path components in lexical order.
3. **Storage Scope Digest Formula**:
   The unique scope identity is the lowercase SHA-256 hexadecimal string over the exact UTF-8 domain prefix, a NUL byte, and the canonical absolute path:
   ```text
   storageScopeDigest = SHA-256("agentry-workspace-authority-lease-v1\0" + canonicalWorkspaceStoragePath)
   ```
   - *Frozen Compatibility Test Vector:*
     - Input Canonical Path: `/tmp/agentry/Workspaces`
     - Expected Digest: `f68efb392cd1119e04cd913c22f942246e478d73e9f1de580e00ad6dd8ab8572`
4. **Strict Containment Check (`containsWorkspaceDocument`)**:
   Workspaces whose document path is located outside the canonical `workspaceStorageDirectory` are not covered by the single-writer lease scope. Such documents remain readable through the routing overlay but are projected strictly as read-only (`DegradedReadOnly`); mutation permits targeting them are rejected fail-closed before persistence.
5. **Private Lock Subdirectory & Permissions**:
   Lease artifacts reside under `<canonical-workspace-storage>/.agentry-domain-runtime/locks/`:
   - Directory permissions: strictly mode `0700` (`rwx------`).
   - `workspace-authority-v1.lock`: POSIX mode `0600` (`rw-------`).
   - `workspace-authority-owner-v1.json`: POSIX mode `0600` (`rw-------`).

#### 2.2 Kernel Lock Ownership via Non-Blocking `flock`
1. **File Descriptor & Syscall Semantics**:
   The lock file is opened using `open(lockFilePath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)` and verified via `fchmod(fd, 0600)`. Acquisition is attempted via `flock(fd, LOCK_EX | LOCK_NB)`.
   - `rc == 0`: Acquisition succeeded.
   - `rc != 0` with `errno == EWOULDBLOCK` or `EAGAIN`: Lock is held by another active process. Contention confirmed; descriptor immediately closed.
   - `rc != 0` with any other errno: Unrecoverable I/O error; fail closed immediately.
2. **Descriptor Retention Rule**:
   The open file descriptor (`fd`) is retained continuously by the owning runtime for its entire mutation authority lifetime.
3. **Kernel `flock` as Sole Ownership Proof**:
   The kernel `flock` is the sole, definitive proof of ownership. User-space files, database flags, or JSON metadata are never authoritative.

#### 2.3 The No-Heartbeat / No-Timestamp Invariant & Process Death Preemption
1. **Explicit Rejection of Heartbeats and Timeouts**:
   The protocol mandates:
   - **NO heartbeat renewal background tasks.**
   - **NO timestamp-based expiration or Time-To-Live (TTL).**
   - **NO deadline checks or periodic lease refresh I/O.**
2. **Vulnerability Analysis on Desktop Operating Systems**:
   On macOS, processes are subject to App Nap, lid-close system sleep, thread starvation, and paging stalls. Heartbeats and timestamp expiry guarantee split-brain divergence: Process B assumes Process A died, acquires the lease, and begins writing; Process A wakes from sleep and completes an in-flight write, corrupting the catalog.
3. **Process Death as Sole Preemption**:
   Preemption occurs strictly through operating system kernel cleanup when the holding process terminates (clean exit, `SIGTERM`, `SIGKILL`, or crash). The macOS kernel reclaims the descriptor and releases the `flock` atomically and instantly. No user-space process may preempt or revoke a live holder's lock based on PID or wall-clock timestamps.

#### 2.4 Diagnostic Owner Metadata
1. **Atomically Staged Metadata**:
   Only after acquiring the kernel `flock`, the holder atomically writes `workspace-authority-owner-v1.json` (`write` to `.tmp` + `fsync` + `rename`):
   ```json
   {
     "version": 1,
     "runtimeID": "4A86FE5D-8CCD-4F95-859B-E8E5B7EF6DB0",
     "lifecycleGeneration": 1,
     "processID": 48123,
     "mode": "app",
     "profileIdentifier": "default",
     "storageScopeDigest": "f68efb392cd1119e04cd913c22f942246e478d73e9f1de580e00ad6dd8ab8572",
     "implementation": "rust",
     "leaseEpoch": "B12E7B31-0199-4789-9A02-39E3618C1D42",
     "acquiredAt": "2026-09-03T05:30:20Z"
   }
   ```
2. **Metadata Invariants**:
   - Stale, corrupt, or missing owner metadata never blocks acquisition of a free kernel lock.
   - Deleting or tampering with `workspace-authority-owner-v1.json` cannot transfer, invalidate, or revoke a live holder's kernel lock.
   - On orderly shutdown, the holder removes `workspace-authority-owner-v1.json` only if its stored `leaseEpoch` matches, drains active permits, calls `flock(fd, LOCK_UN)`, and closes the descriptor.

#### 2.5 Headless MCP & GUI Concurrency (ADR-0011 P8 Alignment)
In accordance with ADR-0011 Addendum P8:
1. **Agent Session Host Non-Claim Invariant**:
   The background Rust `agent-host` process never claims workspace mutation authority (`HostConfig.claim_workspace_authority` defaults to `false`).
2. **Lease Peek Discovery (`observeBlocking`)**:
   Headless MCP instances (`agentry-mcp --backend auto`) probe the lock non-blockingly (`flock(LOCK_EX | LOCK_NB)` then unlock):
   - **Branch A: GUI Present (lock held with `mode == "app"`):**
     `MCPBackendSelection` resolves to `.app` proxy. Tool calls and mutations route via Unix domain socket RPC to the GUI authority. Headless MCP never attempts to claim or steal the GUI lease. During temporary GUI restart windows, auto remains pinned to `.app` proxy and uses reconnect/replay (`MCPReplayState`).
   - **Branch B: GUI Absent (lock free):**
     `MCPBackendSelection` resolves to `.headless` and fence-claims `workspace-authority-v1.lock` directly as standalone direct (`mode == "standalone"`). If another headless CLI holds the lock, the second instance fails closed (`DegradedReadOnly`), issuing zero mutation permits.
   - **Branch C: GUI Startup during Headless Session:**
     GUI encounters `EWOULDBLOCK`, projects degraded read-only, and retries until the bounded CLI session completes and releases the descriptor.

#### 2.6 Mandatory Acquisition Reconciliation Gate & Fault Isolation
1. **Mandatory Reconciliation**: Every successful lease acquisition mints a fresh `leaseEpoch` UUID. Zero command permits may be issued until full durable reconciliation finishes (catalog validation, journal recovery, pending save resolution).
2. **Relinquish-on-Failure Invariant**: If durable reconciliation fails because `workspace-catalog.json` itself is structurally corrupt or unreadable, the runtime immediately calls `relinquishForRetry()`: unlinks metadata, releases `flock`, closes descriptor, and projects `DegradedReadOnly`.
3. **Single-Entry Quarantine**: Missing, untrusted, or corrupted journal evidence in an individual workspace quarantines only that specific row (`Unavailable`), keeping `global_health` as `Writable`. The lease is never surrendered due to single-entry defects.

---

### 3. Strict Fail-Closed Downgrade, Migration & Per-Workspace Fault Isolation Policy

#### 3.1 Elimination of Aggregate Boolean Accumulator
Catalog recovery in Rust (`derive_semantic_full_recovery_v1` in `workspace_persistence_journal.rs`) shall no longer fold individual workspace authoritativeness into a single whole-system boolean:
- **`admission_authoritative &= authoritative;` is retired.**
- Recovery processes each catalog entry independently.

#### 3.2 Per-Workspace Quarantine Set & Admission State
1. **Per-Row Recovery Disposition**:
   - For an entry where `authoritative == false`: The row is classified as `WorkspaceSemanticRecoveryRowV1::Unavailable { reason }` and added to `quarantined_workspaces: HashSet<String>`. In the projection catalog, its health is `DegradedReadOnly(reason)`.
   - For entries where `authoritative == true`: The row is classified as `WorkspaceSemanticRecoveryRowV1::Active`. In the projection catalog, its health is `Writable`.
2. **Admission State Enforcement**:
   - `WorkspaceCommandAdmissionInnerV1` replaces the monolithic `quarantined: bool` with `quarantined_workspaces: HashSet<String>`.
   - In `acquire_command_execution_claim(request)`: If `request.workspace_id` is in `quarantined_workspaces`, the claim is rejected with `WorkspaceWorkingJournalError::WorkspaceQuarantined(reason)`.
   - Unquarantined workspaces and newly created UUIDs are admitted normally.
3. **Global Health Independence Invariant**:
   `global_health` MUST remain `WorkspaceProjectionHealth::Writable` as long as the catalog container itself is valid. Even if $K$ of $N$ workspaces are corrupt ($0 \le K \le N$), healthy workspaces remain fully operational, and users can create new workspaces without restarting or editing files.

#### 3.3 Diagnostic Query Surface
Expose `CoreWorkspaceQuarantineStateV1` via synchronous UniFFI, allowing GUI view models and CLI tools to inspect the exact forensic reasons for quarantine.

#### 3.4 Schema Versioning & Strict Fail-Closed Downgrade
1. **Frozen Schema Baseline**:
   - `workspace.json`: `schema_version = 1`.
   - `workspace-catalog.json`: `schema_version = 1`.
   - `workspace-<id>.journal`: `schema_version = 1`.
2. **Fail-Closed Downgrade Policy**:
   - If an older binary reads a newer schema version ($v > \text{CURRENT\_VERSION}$):
     - **Catalog Level**: If `workspace-catalog.json` has `schema_version > 1`, startup halts immediately with `UnsupportedCatalogSchemaVersion { actual: v, max_supported: 1 }`.
     - **Document Level**: If an individual `workspace.json` has `schema_version > 1`, that row is quarantined as `Unavailable("unsupported_schema_version_\(v)")`. Global health remains `Writable`.
   - **No Lossy Down-Conversion**: Agentry never attempts in-place down-conversion or downgrade migration.
3. **Forward-Fix Only Policy (No Runtime Revert Toggle)**:
   In compliance with Charter §15.3 and ADR-0006, once Rust canonical persistence is cut over, no runtime toggle or dual-path fallback to Swift disk writing is retained in production. All defects must be fixed forward in Rust.

---

### 4. UI ViewModel Hardening, Compensating Cleanup & Test Storage Isolation

#### 4.1 Strict Outcome Verification (`.applied` Required for State Mutations)
1. **Disposition Contract**:
   `WorkspaceManagerViewModel.isSuccessfulDomainOutcome` shall strictly require `outcome.disposition == .applied` for all state-changing commands (`create`, `save`, `contextMutation`, `selectionMutation`, `delete`):
   ```swift
   private static func isSuccessfulDomainMutationOutcome(_ outcome: DomainCommandOutcome) -> Bool {
       outcome.disposition == .applied
   }
   ```
2. **Rejection of Non-Applied Outcomes**:
   - On `create`: `.unchanged` and `.deduplicated` are rejected as failures, throwing `DomainWorkspaceAuthorityOperationError(outcome: outcome)`.
   - On `save`: `.unchanged` indicates that authority rejected the write; it throws an error and triggers diagnostics.
3. **Visible Error Surfacing**:
   Persistence rejections immediately surface user-visible alerts or banners via `domainWorkspaceAuthorityIssue`. Errors are never silently swallowed.

#### 4.2 Atomic Compensating Directory Cleanup
If workspace document persistence fails or throws during workspace creation, `WorkspaceManagerViewModel` immediately purges the allocated directory tree:
```swift
let dir = try ensureWorkspaceDirectoryExists(for: newWorkspace)
do {
    let finalURL = try await saveWorkspaceToFileAsync(
        newWorkspace,
        preserveDiskRepoPathsIfUnchangedSinceBaseline: false,
        source: .createWorkspace
    )
    await WorkspaceDiskWriter.shared.flush(url: finalURL)
} catch {
    // Compensating cleanup: immediately purge unpersisted directory structure
    try? FileManager.default.removeItem(at: dir)
    await MainActor.run {
        self.workspaces.removeAll { $0.id == newWorkspace.id }
        self.pendingCreatePersistenceTasks.removeValue(forKey: newWorkspace.id)
    }
    reportDomainAuthorityFailure(error, workspaceID: newWorkspace.id, operation: "create_workspace")
    throw error
}
```
An identical compensating cleanup pattern applies to `createDefaultWorkspace` and `runtimeOwnedDefaultWorkspaceCandidate`.

#### 4.3 Mandatory Test Storage Isolation & Historical Residue Pruning
1. **Ephemeral Sandboxing in Test Runners**:
   All test runner entry points (`conductor test`, `Scripts/run_tests.sh`, `Makefile`) must provision an isolated sandbox:
   ```bash
   export AGENTRY_APPLICATION_SUPPORT_ROOT="$(mktemp -d /tmp/agentry-test-appsupport-XXXXXX)"
   trap 'rm -rf "$AGENTRY_APPLICATION_SUPPORT_ROOT"' EXIT
   ```
2. **Debug Assertion Trapping Unsandboxed Tests**:
   In `WorkspaceStoragePaths.defaultRoot` and `WorkspaceManagerViewModel.init`, add a debug assertion trapping any test attempting to access the live Application Support container without an override.
3. **Historical Residue Pruning Tooling**:
   Provide a maintenance routine (`./conductor workspace prune-orphans` or `./Scripts/doctor.sh --prune-orphans`) that scans `~/Library/Application Support/Agentry/Workspaces/`, detects directories lacking `workspace.json` that are absent from `workspace-catalog.json`, and safely deletes the 5,732 orphaned empty shells.

---

## Consequences

- **Fault Isolation & Resilience:** Single-workspace journal or document corruption no longer degrades global authority health or relinquishes the storage lease. Healthy workspaces remain writable; corrupted entries are quarantined with fine-grained diagnostics.
- **Data Integrity & Loud Failures:** Requiring `.applied` disposition in `WorkspaceManagerViewModel` completely eliminates silent data loss. Any persistence failure immediately reports an error and triggers visible UI diagnostics.
- **Clean Storage Footprint:** Failed workspace creations automatically purge their pre-allocated directories. Mandatory test sandboxing via `AGENTRY_APPLICATION_SUPPORT_ROOT` prevents test suites from polluting developer storage.
- **Architectural Simplification:** Retiring Swift physical write loops (`DomainPersistenceCoordinator`) eliminates the multi-step directive roundtrip across FFI and prevents dual-writer schema divergence.
- **Single-Writer Safety Across Topologies:** The non-blocking kernel `flock` scoped by storage SHA-256 digest, combined with headless lease peeking and proxying, ensures that GUI and CLI instances never split-brain or clobber workspace state.
- **Immunity to OS Sleep & Freezing:** The strict rejection of heartbeats and TTLs ensures that MacBook lid closures, App Nap, or scheduling stalls cannot cause accidental lease preemption.
- **Increased Engine Surface:** Rust runtime and FFI layers expand to manage per-workspace quarantine sets and direct canonical filesystem writes, requiring strict UniFFI ABI tracking and proptest verification.
- **Forward-Fix Discipline:** In accordance with Charter §15.3 and ADR-0006, forward-fix only is enforced with no rollback switch to legacy Swift writing.

---

## Evidence & Verification

### Forensic Evidence Matrix

| Evidence ID | Source File & Line Location | Exact Finding / Code Snippet | Architectural Implication |
|---|---|---|---|
| **E1: Aggregate Boolean Poison** | `rust/crates/runtime/src/workspace_persistence_journal.rs:3389` | `admission_authoritative &= authoritative;` | Folds all catalog entries into a single boolean; one corrupt journal degrades entire runtime. |
| **E2: Global Health Degradation** | `rust/crates/runtime/src/workspace_persistence_journal.rs:3432–3438` | `let global_health = if admission_authoritative { ... } else { DegradedReadOnly("working_journal_recovery_unavailable") };` | Forces entire catalog into read-only mode upon single entry failure. |
| **E3: Admission Quarantine** | `rust/crates/runtime/src/workspace_persistence_journal.rs:3880–3910` | `inner.quarantined = true;` | Blocks all future execution claims across all workspaces (`InvalidTransaction`). |
| **E4: Lease Relinquishment** | `Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift:1273–1275` & `DomainWorkspaceAuthorityLease.swift:684–688` | `guard durableCatalog.health.acceptsMutations ... else { return false }` -> `failedReason = "canonical_storage_reconciliation_failed"`, `transition(to: .failed)` | Health check failure drops kernel file lock lease, making app permanently read-only. |
| **E5: Silent Outcome Acceptance** | `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:4460–4464` | `outcome.disposition == .applied \|\| outcome.disposition == .unchanged \|\| outcome.disposition == .deduplicated` | Accepts non-writes as success; causes silent loss of newly created workspaces. |
| **E6: Orphan Directory Creation** | `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:2623, 9431–9452` | `_ = try ensureWorkspaceDirectoryExists(for: newWorkspace)` before `saveWorkspaceToFileAsync`, no cleanup in `catch` | Leaves empty directory tree on disk when persistence fails. |
| **E7: Unsandboxed App Support** | `Sources/RepoPromptShared/ProductIdentity/AgentryProductIdentity.swift:15–29` | Falls back to `~/Library/Application Support/Agentry` when `AGENTRY_APPLICATION_SUPPORT_ROOT` is unset | Test suites write directly to live developer storage. |
| **E8: Historical Residue Count** | `docs/investigations/workspace-authority-fix-20260901.md:50, 107` | "5732 个空壳工作区目录尚未清理" | Verified accumulation of 5,732 empty shell directories from unsandboxed tests. |

### Verification Methodology & Acceptance Criteria

1. **Rust Core Engine & Proptest Property Verification**:
   ```bash
   make dev-cargo-test CARGO_PACKAGE=all
   ```
   *Acceptance criterion:* All unit, integration, and proptest property tests pass. Proptests assert that in a catalog with $N$ entries where entry $k$ is corrupt, workspaces $i \neq k$ remain `Writable` and operational.

2. **FFI Determinism & Codegen Gate**:
   ```bash
   make dev-cargo-codegen-check
   ```
   *Acceptance criterion:* `xtask generate --check` exits with status 0 and zero byte divergence against generated Swift/C bindings and ABI manifests.

3. **Repository Guardrails Gate**:
   ```bash
   ./Scripts/guardrails.sh
   ```
   *Acceptance criterion:* Identity, Rust FFI baseline, source layout, license notices, and boundary checks pass with zero violations.

4. **Swift Domain Authority & Workspace Tests**:
   ```bash
   make dev-test FILTER=DomainWorkspaceContextAuthorityTests
   make dev-test FILTER=DomainWorkspaceJournalAuthorityGuardTests
   make dev-test FILTER=Workspace
   ```
   *Acceptance criterion:* All workspace tests pass with storage sandboxing enabled and zero orphan directory leaks.

5. **Contribution Push Preflight Gate**:
   ```bash
   .agents/skills/rpce-contribution-check/scripts/preflight.sh commit
   .agents/skills/rpce-contribution-check/scripts/preflight.sh push
   ```
   *Acceptance criterion:* Mandatory safety preflight confirms clean index secrets, clean push boundaries, and valid repository guardrails.
