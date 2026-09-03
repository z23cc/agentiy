//! JSON-RPC / Claude turn I/O for the hosted executor (design §4.2 / §8 P7).
//!
//! Production [`make_provider_transport`] attaches [`LiveProviderTransport`] when a
//! launch spec/env is present. Tests and hosts without launch info keep
//! [`ScriptedTransport`]. [`UnattachedTransport`] fail-closes.

use std::collections::BTreeMap;

use agentry_proto::agent_host::v1::SessionSpec;

use crate::launch::{LaunchSpec, TransportChoice, resolve_transport_choice};
use crate::live::LiveProviderTransport;

/// One inbound frame from a hosted Codex/ACP (or later Claude) runtime.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProviderInbound {
    Notification {
        method: String,
        params_json: String,
    },
    ServerRequest {
        id_json: String,
        id_display: String,
        method: String,
        params_json: String,
    },
    ProcessExited,
    ProtocolError(String),
}

/// Sync JSON-RPC seam. A later cutover can block on `agent_provider` here without
/// changing the executor or the host router.
pub trait ProviderTransport: Send {
    fn start(&mut self) -> Result<(), String> {
        Ok(())
    }

    fn request(&mut self, method: &str, params_json: &str) -> Result<String, String>;

    fn notify(&mut self, method: &str, params_json: &str) -> Result<(), String> {
        let _ = (method, params_json);
        Ok(())
    }

    fn respond(&mut self, request_id_json: &str, result_json: &str) -> Result<(), String> {
        let _ = (request_id_json, result_json);
        Ok(())
    }

    fn respond_error(
        &mut self,
        request_id_json: &str,
        code: i64,
        message: &str,
    ) -> Result<(), String> {
        let _ = (request_id_json, code, message);
        Ok(())
    }

    fn cancel_in_flight(&mut self) {}

    fn take_inbound(&mut self) -> Vec<ProviderInbound> {
        Vec::new()
    }

    fn shutdown(&mut self) {}
}

/// Fail-closed I/O. Used when a live attach is required but credentials or
/// launch resolution cannot proceed. Requests never look like a completed turn.
#[derive(Debug)]
pub struct UnattachedTransport {
    reason: String,
}

impl Default for UnattachedTransport {
    fn default() -> Self {
        Self {
            reason: "live provider I/O is not attached".to_string(),
        }
    }
}

impl UnattachedTransport {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn because(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }

    #[must_use]
    pub fn reason(&self) -> &str {
        &self.reason
    }
}

impl ProviderTransport for UnattachedTransport {
    fn start(&mut self) -> Result<(), String> {
        Err(format!("unattached: {}", self.reason))
    }

    fn request(&mut self, method: &str, _params_json: &str) -> Result<String, String> {
        Err(format!("unattached: {} ({method})", self.reason))
    }
}

/// Production factory: live I/O when launch spec/env is present, scripted echo
/// when it is missing, fail-closed unattached when a required credential is not
/// available.
#[must_use]
pub fn make_provider_transport(spec: &SessionSpec) -> Box<dyn ProviderTransport> {
    match resolve_transport_choice(spec) {
        TransportChoice::Scripted => Box::new(ScriptedTransport::echo()),
        TransportChoice::Unattached { reason } => Box::new(UnattachedTransport::because(reason)),
        TransportChoice::Live(launch) => match LiveProviderTransport::new(launch) {
            Ok(live) => Box::new(live),
            Err(reason) => Box::new(UnattachedTransport::because(reason)),
        },
    }
}

/// Test helper: construct live I/O for a missing binary without touching env.
/// # Errors
///
/// Returns when the live transport cannot be constructed (identity or hub).
pub fn live_transport_for_missing_binary() -> Result<LiveProviderTransport, String> {
    LiveProviderTransport::new(LaunchSpec::missing_binary(crate::launch::LiveFamily::Codex))
}

type ScriptedHandler =
    Box<dyn FnMut(&str) -> Result<(String, Vec<ProviderInbound>), String> + Send>;

/// In-memory JSON-RPC fixture. No process, no network.
pub struct ScriptedTransport {
    handlers: BTreeMap<String, ScriptedHandler>,
    recorded: Vec<(String, String)>,
    recorded_responds: Vec<(String, String)>,
    inbound: Vec<ProviderInbound>,
}

impl ScriptedTransport {
    #[must_use]
    pub fn new() -> Self {
        Self {
            handlers: BTreeMap::new(),
            recorded: Vec::new(),
            recorded_responds: Vec::new(),
            inbound: Vec::new(),
        }
    }

    /// Family-neutral echo that completes one Codex or ACP turn without a subprocess.
    #[must_use]
    pub fn echo() -> Self {
        let mut transport = Self::new();
        transport.set_json("initialize", "{}");
        transport.set_json("thread/start", r#"{"thread":{"id":"hosted-thread"}}"#);
        transport.set_json("session/new", r#"{"sessionId":"hosted-session"}"#);
        transport.set_handler("turn/start", |params| {
            let text = extract_prompt_text(params);
            let inbound = vec![
                ProviderInbound::Notification {
                    method: "item/agentMessage/delta".to_string(),
                    params_json: format!(
                        r#"{{"delta":{}}}"#,
                        json_string(&format!("hosted:{text}"))
                    ),
                },
                ProviderInbound::Notification {
                    method: "turn/completed".to_string(),
                    params_json: r#"{"turn":{"id":"hosted-turn","status":"completed"}}"#
                        .to_string(),
                },
            ];
            Ok((r#"{"turn":{"id":"hosted-turn"}}"#.to_string(), inbound))
        });
        transport.set_handler("session/prompt", |params| {
            let text = extract_prompt_text(params);
            let inbound = vec![ProviderInbound::Notification {
                method: "session/update".to_string(),
                params_json: format!(
                    r#"{{"update":{{"sessionUpdate":"agent_message_chunk","content":{{"type":"text","text":{}}}}}}}"#,
                    json_string(&format!("hosted:{text}"))
                ),
            }];
            Ok((r#"{"stopReason":"end_turn"}"#.to_string(), inbound))
        });
        transport.set_handler("user_message", |params| {
            let text = extract_prompt_text(params);
            Ok((
                format!(r#"{{"text":{}}}"#, json_string(&format!("hosted:{text}"))),
                Vec::new(),
            ))
        });
        transport
    }

    pub fn set_json(&mut self, method: impl Into<String>, body: impl Into<String>) {
        let body = body.into();
        self.set_handler(method, move |_| Ok((body.clone(), Vec::new())));
    }

    pub fn set_handler<F>(&mut self, method: impl Into<String>, handler: F)
    where
        F: FnMut(&str) -> Result<(String, Vec<ProviderInbound>), String> + Send + 'static,
    {
        self.handlers.insert(method.into(), Box::new(handler));
    }

    pub fn emit(&mut self, inbound: ProviderInbound) {
        self.inbound.push(inbound);
    }

    #[must_use]
    pub fn recorded_requests(&self) -> &[(String, String)] {
        &self.recorded
    }

    #[must_use]
    pub fn recorded_responds(&self) -> &[(String, String)] {
        &self.recorded_responds
    }
}

impl Default for ScriptedTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl ProviderTransport for ScriptedTransport {
    fn request(&mut self, method: &str, params_json: &str) -> Result<String, String> {
        self.recorded
            .push((method.to_string(), params_json.to_string()));
        if let Some(handler) = self.handlers.get_mut(method) {
            let (body, inbound) = handler(params_json)?;
            self.inbound.extend(inbound);
            return Ok(body);
        }
        Ok("{}".to_string())
    }

    fn notify(&mut self, method: &str, params_json: &str) -> Result<(), String> {
        self.recorded
            .push((method.to_string(), params_json.to_string()));
        Ok(())
    }

    fn respond(&mut self, request_id_json: &str, result_json: &str) -> Result<(), String> {
        self.recorded_responds
            .push((request_id_json.to_string(), result_json.to_string()));
        Ok(())
    }

    fn respond_error(
        &mut self,
        request_id_json: &str,
        code: i64,
        message: &str,
    ) -> Result<(), String> {
        self.recorded_responds.push((
            request_id_json.to_string(),
            format!(
                r#"{{"error":{{"code":{code},"message":{}}}}}"#,
                json_string(message)
            ),
        ));
        Ok(())
    }

    fn take_inbound(&mut self) -> Vec<ProviderInbound> {
        std::mem::take(&mut self.inbound)
    }
}

fn extract_prompt_text(params_json: &str) -> String {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(params_json) else {
        return String::new();
    };
    if let Some(text) = value.get("input").and_then(first_text_in_blocks) {
        return text;
    }
    if let Some(text) = value.get("prompt").and_then(first_text_in_blocks) {
        return text;
    }
    value
        .get("text")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn first_text_in_blocks(value: &serde_json::Value) -> Option<String> {
    value.as_array()?.iter().find_map(|item| {
        item.get("text")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string)
    })
}

fn json_string(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string())
}
