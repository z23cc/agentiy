mod common;

use agentry_runtime::{
    AdmissionOutcome, CancelOutcome, OperationRegistry, OperationState, RegistryError,
    RequestFingerprint, TerminalOutcome,
};
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
