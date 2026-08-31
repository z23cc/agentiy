use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex};

use serde_json::{Number, Value};

use super::AgentProviderScopeError;

/// JSON-RPC identifiers retain both their JSON type and numeric spelling. A string `"1"`,
/// integer `1`, and number `1.0` are distinct protocol identities.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum JsonRpcId {
    Number(Number),
    String(String),
}

impl JsonRpcId {
    pub fn from_value(value: &Value) -> Option<Self> {
        match value {
            Value::Number(number) => Some(Self::Number(number.clone())),
            Value::String(value) if !value.is_empty() => Some(Self::String(value.clone())),
            _ => None,
        }
    }

    pub fn key(&self) -> String {
        match self {
            Self::Number(number) => format!("n:{number}"),
            Self::String(value) => format!("s:{value}"),
        }
    }

    pub fn value(&self) -> Value {
        match self {
            Self::Number(number) => Value::Number(number.clone()),
            Self::String(value) => Value::String(value.clone()),
        }
    }

    pub fn encoded(&self) -> Vec<u8> {
        serde_json::to_vec(&self.value()).unwrap_or_default()
    }
}

pub type RpcWaiter = Arc<(
    Mutex<Option<Result<JsonRpcCompletion, AgentProviderScopeError>>>,
    Condvar,
)>;

pub struct JsonRpcPending {
    pub method: String,
    pub cancellation_token: Option<String>,
    pub waiter: RpcWaiter,
}

pub struct JsonRpcCompletion {
    pub result: Value,
    pub inbound_sequence: u64,
}

pub struct JsonRpcState {
    next_request_id: u64,
    next_inbound_sequence: u64,
    pending: HashMap<String, JsonRpcPending>,
    cancelled_tokens: VecDeque<String>,
}

impl JsonRpcState {
    pub fn new() -> Self {
        Self {
            next_request_id: 1,
            next_inbound_sequence: 0,
            pending: HashMap::new(),
            cancelled_tokens: VecDeque::new(),
        }
    }

    pub fn allocate_request<F>(
        &mut self,
        method: &str,
        cancellation_token: Option<&str>,
        cancellation_error: F,
    ) -> Result<(JsonRpcId, RpcWaiter), AgentProviderScopeError>
    where
        F: FnOnce(String) -> AgentProviderScopeError,
    {
        let cancellation_token = cancellation_token
            .filter(|token| !token.is_empty())
            .map(ToOwned::to_owned);
        if let Some(token) = cancellation_token.as_ref()
            && remove_cancelled_token(&mut self.cancelled_tokens, token)
        {
            return Err(cancellation_error(method.to_owned()));
        }
        if self.pending.len() >= 256 {
            return Err(AgentProviderScopeError::InvalidArgument(
                "too many pending provider requests",
            ));
        }
        let request_id = JsonRpcId::Number(Number::from(self.next_request_id));
        self.next_request_id = self.next_request_id.saturating_add(1);
        let waiter = Arc::new((Mutex::new(None), Condvar::new()));
        self.pending.insert(
            request_id.key(),
            JsonRpcPending {
                method: method.to_owned(),
                cancellation_token,
                waiter: Arc::clone(&waiter),
            },
        );
        Ok((request_id, waiter))
    }

    pub fn take_pending(&mut self, id: &JsonRpcId) -> Option<JsonRpcPending> {
        self.pending.remove(&id.key())
    }

    pub fn remove_pending_by_key(&mut self, key: &str) -> Option<JsonRpcPending> {
        self.pending.remove(key)
    }

    pub fn cancel_token(&mut self, token: &str) -> Option<JsonRpcPending> {
        let pending_key = self.pending.iter().find_map(|(key, pending)| {
            (pending.cancellation_token.as_deref() == Some(token)).then(|| key.clone())
        });
        if let Some(key) = pending_key {
            self.pending.remove(&key)
        } else {
            if self.cancelled_tokens.len() >= 256 {
                self.cancelled_tokens.pop_front();
            }
            self.cancelled_tokens.push_back(token.to_owned());
            None
        }
    }

    pub fn next_inbound_sequence(&mut self) -> u64 {
        self.next_inbound_sequence = self.next_inbound_sequence.saturating_add(1);
        self.next_inbound_sequence
    }

    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    pub fn drain_pending(&mut self) -> Vec<JsonRpcPending> {
        self.pending.drain().map(|(_, pending)| pending).collect()
    }
}

impl Default for JsonRpcState {
    fn default() -> Self {
        Self::new()
    }
}

pub fn settle_pending(
    pending: JsonRpcPending,
    result: Result<JsonRpcCompletion, AgentProviderScopeError>,
) {
    let (lock, wake) = &*pending.waiter;
    *lock
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(result);
    wake.notify_all();
}

fn remove_cancelled_token(tokens: &mut VecDeque<String>, token: &str) -> bool {
    let Some(index) = tokens.iter().position(|candidate| candidate == token) else {
        return false;
    };
    tokens.remove(index);
    true
}
