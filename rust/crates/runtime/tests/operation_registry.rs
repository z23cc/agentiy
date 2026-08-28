mod common;

use agentry_runtime::{
    AdmissionOutcome, CancelOutcome, ManagedOperationDirective, ManagedOperationStopReason,
    OperationRegistry, OperationState, RegistryError, RequestFingerprint, TerminalOutcome,
};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[test]
fn duplicate_and_collision_are_deterministic() {
    let identity = common::identity('a');
    let registry = OperationRegistry::new(identity.clone(), Duration::from_secs(1));
    let request = common::request(1, &identity);
    assert_eq!(
        registry.admit(request.clone()),
        Ok(AdmissionOutcome::Accepted)
    );
    assert_eq!(
        registry.admit(request.clone()),
        Ok(AdmissionOutcome::Duplicate(OperationState::Admitted))
    );

    let mut collision = request;
    collision.fingerprint = RequestFingerprint::repeated('f');
    assert_eq!(
        registry.admit(collision),
        Err(RegistryError::OperationConflict)
    );
    assert_eq!(registry.diagnostics().collisions, 1);
}

#[test]
fn cancel_before_admission_is_idempotent_and_bound_to_first_request() {
    let identity = common::identity('a');
    let registry = OperationRegistry::new(identity.clone(), Duration::from_secs(1));
    let id = common::operation_id(2);
    assert_eq!(
        registry.cancel(&identity, id.clone()),
        Ok(CancelOutcome::Tombstoned)
    );
    assert_eq!(
        registry.cancel(&identity, id.clone()),
        Ok(CancelOutcome::Tombstoned)
    );
    assert_eq!(registry.tombstone_count(), 1);

    let request = common::request(2, &identity);
    assert_eq!(
        registry.admit(request.clone()),
        Ok(AdmissionOutcome::Duplicate(OperationState::Terminal(
            TerminalOutcome::Cancelled
        )))
    );
    assert_eq!(registry.active_count(), 0);
    let mut collision = request.clone();
    collision.fingerprint = RequestFingerprint::repeated('e');
    assert_eq!(
        registry.admit(collision),
        Err(RegistryError::OperationConflict)
    );
    assert_eq!(
        registry.admit(request),
        Ok(AdmissionOutcome::Duplicate(OperationState::Terminal(
            TerminalOutcome::Cancelled
        )))
    );
}

#[test]
fn expired_cancel_tombstone_allows_later_admission() {
    let identity = common::identity('a');
    let registry = OperationRegistry::new(identity.clone(), Duration::from_millis(10));
    let now = Instant::now();
    let id = common::operation_id(3);
    assert_eq!(
        registry.cancel_at(&identity, id, now),
        Ok(CancelOutcome::Tombstoned)
    );
    assert_eq!(
        registry.admit_at(
            common::request(3, &identity),
            SystemTime::now(),
            now + Duration::from_millis(11)
        ),
        Ok(AdmissionOutcome::Accepted)
    );
    assert_eq!(registry.diagnostics().expired_tombstones, 1);
}

#[test]
fn deadline_is_converted_once_and_expired_admission_is_rejected() {
    let identity = common::identity('a');
    let registry = OperationRegistry::new(identity.clone(), Duration::from_secs(1));
    let wall = UNIX_EPOCH + Duration::from_secs(10);
    let monotonic = Instant::now();

    let mut expired = common::request(4, &identity);
    expired.deadline_unix_millis = Some(10_000);
    assert_eq!(
        registry.admit_at(expired, wall, monotonic),
        Err(RegistryError::DeadlineExpired)
    );

    let mut future = common::request(5, &identity);
    future.deadline_unix_millis = Some(10_050);
    assert_eq!(
        registry.admit_at(future, wall, monotonic),
        Ok(AdmissionOutcome::Accepted)
    );
    assert_eq!(
        registry.expire_deadlines(monotonic + Duration::from_millis(49)),
        0
    );
    assert_eq!(
        registry.expire_deadlines(monotonic + Duration::from_millis(50)),
        1
    );
}

#[test]
fn first_terminal_wins_and_late_result_is_diagnostic_only() {
    let identity = common::identity('a');
    let registry = OperationRegistry::new(identity.clone(), Duration::from_secs(1));
    let request = common::request(6, &identity);
    let id = request.operation_id.clone();
    registry.admit(request).expect("admit");
    assert_eq!(
        registry.resolve_terminal(&identity, &id, TerminalOutcome::Success),
        Ok(OperationState::Terminal(TerminalOutcome::Success))
    );
    assert_eq!(
        registry.resolve_terminal(&identity, &id, TerminalOutcome::Cancelled),
        Ok(OperationState::Terminal(TerminalOutcome::Success))
    );
    assert_eq!(registry.diagnostics().late_terminal_results, 1);
}

#[test]
fn managed_cancel_abandon_preserves_tombstone_and_fences_aba() {
    let identity = common::identity('a');
    let registry = Arc::new(OperationRegistry::new(
        identity.clone(),
        Duration::from_secs(1),
    ));
    let request = common::request(7, &identity);
    let operation_id = request.operation_id.clone();
    let (first, directive) = registry
        .attach_managed(request.clone())
        .expect("first managed attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);
    let first_generation = first.generation();
    assert_eq!(
        registry.cancel(&identity, operation_id.clone()),
        Ok(CancelOutcome::Requested)
    );
    assert_eq!(
        first.checkpoint(),
        Ok(ManagedOperationDirective::Stop(
            ManagedOperationStopReason::Cancelled
        ))
    );
    assert!(first.abandon().expect("exact abandon"));
    assert_eq!(registry.tombstone_count(), 1);

    let (second, directive) = registry
        .attach_managed(request)
        .expect("tombstoned managed attachment");
    assert_ne!(second.generation(), first_generation);
    assert_eq!(
        directive,
        ManagedOperationDirective::Stop(ManagedOperationStopReason::Cancelled)
    );
    assert_eq!(first.checkpoint(), Err(RegistryError::OperationConflict));
    assert_eq!(
        second.resolve_terminal(TerminalOutcome::Cancelled),
        Ok(OperationState::Terminal(TerminalOutcome::Cancelled))
    );
}

#[test]
fn managed_deadline_and_authority_winner_are_deterministic() {
    let identity = common::identity('a');
    let registry = Arc::new(OperationRegistry::new(
        identity.clone(),
        Duration::from_secs(1),
    ));
    let wall = UNIX_EPOCH + Duration::from_secs(20);
    let monotonic = Instant::now();
    let mut expiring = common::request(8, &identity);
    expiring.deadline_unix_millis = Some(20_010);
    let (deadline_claim, directive) = registry
        .attach_managed_at(expiring, wall, monotonic)
        .expect("deadline attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);
    assert_eq!(
        deadline_claim.checkpoint_at(monotonic + Duration::from_millis(10)),
        Ok(ManagedOperationDirective::Stop(
            ManagedOperationStopReason::DeadlineExceeded
        ))
    );
    assert!(deadline_claim.abandon().expect("deadline abandon"));

    let authority_request = common::request(9, &identity);
    let authority_id = authority_request.operation_id.clone();
    let (authority_claim, directive) = registry
        .attach_managed(authority_request.clone())
        .expect("authority attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);
    assert_eq!(
        authority_claim.begin_authority(),
        Ok(ManagedOperationDirective::ContinueExecution)
    );
    assert_eq!(
        registry.cancel(&identity, authority_id),
        Ok(CancelOutcome::AlreadyTerminal)
    );
    assert_eq!(
        authority_claim.checkpoint(),
        Ok(ManagedOperationDirective::ContinueExecution)
    );

    // A physical-I/O failure after authority admission establishes no workspace receipt. Exact
    // cleanup must therefore remove this generation so the P5 claim can be retried.
    assert!(
        authority_claim
            .abandon()
            .expect("post-authority failure cleanup")
    );
    let (retry_claim, retry_directive) = registry
        .attach_managed(authority_request)
        .expect("retry attachment");
    assert_eq!(
        retry_directive,
        ManagedOperationDirective::ContinueExecution
    );
    assert_ne!(retry_claim.generation(), authority_claim.generation());
    assert_eq!(
        authority_claim.checkpoint(),
        Err(RegistryError::OperationConflict)
    );
    assert_eq!(
        retry_claim.resolve_terminal(TerminalOutcome::Success),
        Ok(OperationState::Terminal(TerminalOutcome::Success))
    );
}

#[test]
fn managed_shutdown_stop_is_first_and_terminal_is_sticky() {
    let identity = common::identity('a');
    let registry = Arc::new(OperationRegistry::new(
        identity.clone(),
        Duration::from_secs(1),
    ));
    let (claim, directive) = registry
        .attach_managed(common::request(10, &identity))
        .expect("managed attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);
    assert_eq!(registry.begin_shutdown(), 1);
    assert_eq!(
        claim.checkpoint(),
        Ok(ManagedOperationDirective::Stop(
            ManagedOperationStopReason::ShutdownRequested
        ))
    );
    assert_eq!(
        claim.resolve_terminal(TerminalOutcome::Cancelled),
        Ok(OperationState::Terminal(TerminalOutcome::Cancelled))
    );
    assert_eq!(
        claim.resolve_terminal(TerminalOutcome::Success),
        Ok(OperationState::Terminal(TerminalOutcome::Cancelled))
    );
    assert_eq!(registry.diagnostics().late_terminal_results, 1);
}

#[test]
fn stale_identity_and_shutdown_fail_closed() {
    let identity = common::identity('a');
    let stale = common::identity('d');
    let registry = OperationRegistry::new(identity.clone(), Duration::from_secs(1));
    assert_eq!(
        registry.admit(common::request(7, &stale)),
        Err(RegistryError::StaleRuntimeIdentity)
    );
    registry.begin_shutdown();
    assert_eq!(
        registry.admit(common::request(8, &identity)),
        Err(RegistryError::ShuttingDown)
    );
    assert_eq!(registry.active_count(), 0);
}
