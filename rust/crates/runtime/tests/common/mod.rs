#![allow(dead_code)]

use agentry_runtime::{
    AdmissionRequest, OperationId, RequestFingerprint, RuntimeIdentity, ScopeId,
};

pub fn identity(nonce: char) -> RuntimeIdentity {
    RuntimeIdentity::new(
        1,
        std::iter::repeat_n(nonce, 32).collect::<String>(),
        "b".repeat(64),
        "c".repeat(64),
    )
    .expect("test identity must be valid")
}

pub fn operation_id(value: u128) -> OperationId {
    OperationId::from_u128(value)
}
pub fn scope_id(value: u128) -> ScopeId {
    ScopeId::from_u128(value)
}

pub fn request(value: u128, identity: &RuntimeIdentity) -> AdmissionRequest {
    AdmissionRequest {
        operation_id: operation_id(value),
        fingerprint: RequestFingerprint::repeated(
            char::from_digit((value % 16) as u32, 16).expect("hex"),
        ),
        scope: scope_id(1),
        deadline_unix_millis: None,
        runtime_identity: identity.clone(),
    }
}
