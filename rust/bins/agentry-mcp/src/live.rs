//! Live [`ProviderTransport`] over `agent_claude` / `agent_provider`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use agentry_runtime::agent_claude::{
    AgentClaudeScope, AgentClaudeScopeConfig, PermissionDecisionInput,
    ScopeRegistry as ClaudeRegistry,
};
use agentry_runtime::agent_provider::{
    AgentProviderScope, AgentProviderScopeConfig, ProviderProtocol,
    ScopeRegistry as ProviderRegistry,
};
use agentry_runtime::{
    DEFAULT_DRAIN_MAX_BYTES, DEFAULT_DRAIN_MAX_EVENTS, DrainOutcome, RuntimeIdentity, ScopeId,
    SubscriptionConfig, SubscriptionHub, SubscriptionId,
};
use serde_json::{Value, json};

use crate::launch::{LaunchSpec, LiveFamily};
use crate::transport::{ProviderInbound, ProviderTransport};

const DEFAULT_BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(30);
const DEFAULT_TURN_TIMEOUT: Duration = Duration::from_mins(10);

enum LiveScope {
    Claude {
        _registry: ClaudeRegistry,
        scope: Arc<AgentClaudeScope>,
    },
    Provider {
        _registry: ProviderRegistry,
        scope: Arc<AgentProviderScope>,
        protocol: ProviderProtocol,
    },
}

/// Production I/O. Construction does not spawn; [`ProviderTransport::start`] does.
pub struct LiveProviderTransport {
    launch: LaunchSpec,
    identity: RuntimeIdentity,
    hub: Arc<SubscriptionHub>,
    subscription: Option<SubscriptionId>,
    inbound: Vec<ProviderInbound>,
    scope: Option<LiveScope>,
    cancel_token: Option<String>,
    claude_generation: Option<u64>,
}

impl LiveProviderTransport {
    /// # Errors
    ///
    /// Returns when the host identity or subscription hub cannot be created.
    pub fn new(launch: LaunchSpec) -> Result<Self, String> {
        let identity = host_identity()?;
        let hub = SubscriptionHub::new(identity.clone()).map_err(|error| error.to_string())?;
        Ok(Self {
            launch,
            identity,
            hub: Arc::new(hub),
            subscription: None,
            inbound: Vec::new(),
            scope: None,
            cancel_token: None,
            claude_generation: None,
        })
    }

    #[must_use]
    pub fn command(&self) -> &str {
        &self.launch.command
    }

    fn attach_subscription(&mut self, scope_id: ScopeId) -> Result<(), String> {
        let bootstrap = self
            .hub
            .open_subscription(
                &self.identity,
                scope_id,
                SubscriptionConfig::default(),
                Vec::new,
            )
            .map_err(|error| error.to_string())?;
        self.subscription = Some(bootstrap.subscription_id);
        Ok(())
    }

    fn drain_hub(&mut self) {
        let Some(subscription) = self.subscription else {
            return;
        };
        loop {
            let outcome = self.hub.try_drain(
                &self.identity,
                subscription,
                DEFAULT_DRAIN_MAX_EVENTS,
                DEFAULT_DRAIN_MAX_BYTES,
            );
            match outcome {
                Ok(DrainOutcome::Batch(batch)) => {
                    let has_more = batch.has_more;
                    for event in batch.events {
                        if let Some(inbound) = map_event(&event.payload, self.launch.family) {
                            self.inbound.push(inbound);
                        }
                    }
                    if !has_more {
                        break;
                    }
                }
                Ok(DrainOutcome::Oversize(_)) | Err(_) => break,
            }
        }
    }

    fn spawn_claude(&mut self) -> Result<(), String> {
        let registry = ClaudeRegistry::new();
        let mut config = AgentClaudeScopeConfig::default();
        config.command.clone_from(&self.launch.command);
        config.arguments.clone_from(&self.launch.arguments);
        config.environment.clone_from(&self.launch.environment);
        config
            .working_directory
            .clone_from(&self.launch.working_directory);
        let scope = registry.open_scope(self.identity.clone(), config);
        let scope_id = scope.scope_id().to_subscription_scope_id();
        scope.attach_event_sink(Arc::clone(&self.hub), scope_id.clone());
        self.attach_subscription(scope_id)?;
        scope
            .start_or_resume(
                &self.identity,
                self.launch.resume_session_id.clone(),
                self.launch.model.clone(),
                self.launch.effort.clone(),
            )
            .map_err(|error| error.to_string())?;
        self.scope = Some(LiveScope::Claude {
            _registry: registry,
            scope,
        });
        self.drain_hub();
        Ok(())
    }

    fn spawn_provider(&mut self, protocol: ProviderProtocol) -> Result<(), String> {
        let registry = ProviderRegistry::new();
        let scope = registry.open_scope(
            self.identity.clone(),
            AgentProviderScopeConfig {
                command: self.launch.command.clone(),
                arguments: self.launch.arguments.clone(),
                environment: self.launch.environment.clone(),
                working_directory: self.launch.working_directory.clone(),
                protocol,
                max_stderr_bytes: 8_192,
            },
        );
        let scope_id = scope.id().to_subscription_scope_id();
        scope.attach_event_sink(Arc::clone(&self.hub), scope_id.clone());
        self.attach_subscription(scope_id)?;
        scope
            .start(&self.identity)
            .map_err(|error| error.to_string())?;
        self.scope = Some(LiveScope::Provider {
            _registry: registry,
            scope,
            protocol,
        });
        self.drain_hub();
        Ok(())
    }

    fn request_claude(&mut self, method: &str, params_json: &str) -> Result<String, String> {
        let Some(LiveScope::Claude { scope, .. }) = self.scope.as_ref() else {
            return Err("claude scope is not attached".to_string());
        };
        if method != "user_message" && method != "prompt" {
            return Ok("{}".to_string());
        }
        let text = extract_text(params_json);
        let generation = scope
            .send_user_message(&self.identity, &text)
            .map_err(|error| error.to_string())?;
        self.claude_generation = Some(generation);
        let deadline = Instant::now() + turn_timeout();
        let mut assistant = String::new();
        loop {
            self.drain_hub();
            for item in &self.inbound {
                match item {
                    ProviderInbound::Notification {
                        method,
                        params_json,
                    } if method == "assistantDelta" => {
                        if let Some(delta) = json_string_at(params_json, "text") {
                            assistant.push_str(&delta);
                        }
                    }
                    ProviderInbound::Notification {
                        method,
                        params_json,
                    } if method == "turnCompleted" => {
                        let status = json_string_at(params_json, "status").unwrap_or_default();
                        if status == "failed" {
                            return Err("claude turn failed".to_string());
                        }
                        return Ok(json!({ "text": assistant }).to_string());
                    }
                    ProviderInbound::ProcessExited => {
                        return Err("claude process exited".to_string());
                    }
                    ProviderInbound::ProtocolError(message) => {
                        return Err(message.clone());
                    }
                    _ => {}
                }
            }
            if Instant::now() >= deadline {
                return Err("claude turn timed out".to_string());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn request_provider(&mut self, method: &str, params_json: &str) -> Result<String, String> {
        let Some(LiveScope::Provider {
            scope, protocol, ..
        }) = self.scope.as_ref()
        else {
            return Err("provider scope is not attached".to_string());
        };
        let token = crate::util::uuid_v4();
        self.cancel_token = Some(token.clone());
        let params = if params_json.trim().is_empty() {
            None
        } else {
            Some(params_json.as_bytes())
        };
        let timeout = Some(timeout_for(method));
        let result = match protocol {
            ProviderProtocol::CodexAppServer => scope
                .codex_request(
                    &self.identity,
                    method,
                    params,
                    timeout,
                    Some(token.as_str()),
                )
                .map_err(|error| error.to_string()),
            ProviderProtocol::Acp => scope
                .acp_request(
                    &self.identity,
                    method,
                    params,
                    timeout,
                    Some(token.as_str()),
                )
                .map(|response| response.result)
                .map_err(|error| error.to_string()),
            ProviderProtocol::ClaudeHeadless => {
                Err("claude headless is not the hosted interactive path".to_string())
            }
        };
        self.cancel_token = None;
        self.drain_hub();
        let bytes = result?;
        Ok(String::from_utf8(bytes).unwrap_or_else(|_| "{}".to_string()))
    }
}

impl ProviderTransport for LiveProviderTransport {
    fn start(&mut self) -> Result<(), String> {
        if self.scope.is_some() {
            return Ok(());
        }
        match self.launch.family {
            LiveFamily::Claude => self.spawn_claude(),
            LiveFamily::Codex => self.spawn_provider(ProviderProtocol::CodexAppServer),
            LiveFamily::Acp => self.spawn_provider(ProviderProtocol::Acp),
        }
    }

    fn request(&mut self, method: &str, params_json: &str) -> Result<String, String> {
        if self.scope.is_none() {
            return Err(format!(
                "live provider is not started ({method}); binary was not spawned"
            ));
        }
        match self.launch.family {
            LiveFamily::Claude => self.request_claude(method, params_json),
            LiveFamily::Codex | LiveFamily::Acp => self.request_provider(method, params_json),
        }
    }

    fn notify(&mut self, method: &str, params_json: &str) -> Result<(), String> {
        let Some(LiveScope::Provider {
            scope, protocol, ..
        }) = self.scope.as_ref()
        else {
            return Ok(());
        };
        let params = if params_json.trim().is_empty() {
            None
        } else {
            Some(params_json.as_bytes())
        };
        match protocol {
            ProviderProtocol::CodexAppServer => scope
                .codex_notify(&self.identity, method, params)
                .map(|_| ())
                .map_err(|error| error.to_string()),
            ProviderProtocol::Acp => scope
                .acp_notify(&self.identity, method, params, None)
                .map(|_| ())
                .map_err(|error| error.to_string()),
            ProviderProtocol::ClaudeHeadless => Ok(()),
        }
    }

    fn respond(&mut self, request_id_json: &str, result_json: &str) -> Result<(), String> {
        match self.scope.as_ref() {
            Some(LiveScope::Claude { scope, .. }) => {
                let id = display_id(request_id_json);
                scope
                    .respond_permission(&self.identity, &id, claude_decision(result_json))
                    .map_err(|error| error.to_string())
            }
            Some(LiveScope::Provider {
                scope, protocol, ..
            }) => {
                let id = request_id_json.as_bytes();
                let result = result_json.as_bytes();
                match protocol {
                    ProviderProtocol::CodexAppServer => scope
                        .codex_respond(&self.identity, id, result)
                        .map(|_| ())
                        .map_err(|error| error.to_string()),
                    ProviderProtocol::Acp => scope
                        .acp_respond(&self.identity, id, result)
                        .map(|_| ())
                        .map_err(|error| error.to_string()),
                    ProviderProtocol::ClaudeHeadless => Ok(()),
                }
            }
            None => Err("live provider is not started".to_string()),
        }
    }

    fn respond_error(
        &mut self,
        request_id_json: &str,
        code: i64,
        message: &str,
    ) -> Result<(), String> {
        let Some(LiveScope::Provider {
            scope, protocol, ..
        }) = self.scope.as_ref()
        else {
            return Ok(());
        };
        let id = request_id_json.as_bytes();
        match protocol {
            ProviderProtocol::CodexAppServer => scope
                .codex_respond_error(&self.identity, id, code, message, None)
                .map(|_| ())
                .map_err(|error| error.to_string()),
            ProviderProtocol::Acp => scope
                .acp_respond_error(&self.identity, id, code, message, None)
                .map(|_| ())
                .map_err(|error| error.to_string()),
            ProviderProtocol::ClaudeHeadless => Ok(()),
        }
    }

    fn cancel_in_flight(&mut self) {
        match self.scope.as_ref() {
            Some(LiveScope::Claude { scope, .. }) => {
                let generation = self.claude_generation.unwrap_or(0);
                let _ =
                    scope.interrupt_turn(&self.identity, generation, "host interrupt".to_string());
            }
            Some(LiveScope::Provider {
                scope, protocol, ..
            }) => {
                if let Some(token) = self.cancel_token.as_deref() {
                    match protocol {
                        ProviderProtocol::CodexAppServer => {
                            let _ = scope.codex_cancel(&self.identity, token);
                        }
                        ProviderProtocol::Acp => {
                            let _ = scope.acp_cancel(&self.identity, token);
                        }
                        ProviderProtocol::ClaudeHeadless => {}
                    }
                }
            }
            None => {}
        }
        self.drain_hub();
    }

    fn take_inbound(&mut self) -> Vec<ProviderInbound> {
        self.drain_hub();
        std::mem::take(&mut self.inbound)
    }

    fn shutdown(&mut self) {
        match self.scope.take() {
            Some(LiveScope::Claude { scope, .. }) => {
                let _ = scope.shutdown(&self.identity);
            }
            Some(LiveScope::Provider { scope, .. }) => {
                let _ = scope.shutdown(&self.identity);
            }
            None => {}
        }
        if let Some(subscription) = self.subscription.take() {
            let _ = self.hub.close_subscription(&self.identity, subscription);
        }
        self.inbound.clear();
        self.cancel_token = None;
        self.claude_generation = None;
    }
}

impl Drop for LiveProviderTransport {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn host_identity() -> Result<RuntimeIdentity, String> {
    let fingerprint = std::env::var("AGENTRY_HOST_BUILD_FINGERPRINT")
        .or_else(|_| std::env::var("AGENTRY_CORE_BUILD_FINGERPRINT"))
        .ok()
        .and_then(|value| valid_hex(&value, 64))
        .unwrap_or_else(|| "0".repeat(64));
    RuntimeIdentity::fresh(&fingerprint, &"0".repeat(64)).map_err(|error| error.to_string())
}

fn valid_hex(value: &str, length: usize) -> Option<String> {
    if value.len() == length && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Some(value.to_ascii_lowercase())
    } else {
        None
    }
}

fn timeout_for(method: &str) -> Duration {
    match method {
        "turn/start" | "session/prompt" | "user_message" | "prompt" => turn_timeout(),
        _ => bootstrap_timeout(),
    }
}

fn bootstrap_timeout() -> Duration {
    parse_timeout_ms(
        "AGENTRY_AGENT_HOST_BOOTSTRAP_TIMEOUT_MS",
        DEFAULT_BOOTSTRAP_TIMEOUT,
    )
}

fn turn_timeout() -> Duration {
    parse_timeout_ms("AGENTRY_AGENT_HOST_TURN_TIMEOUT_MS", DEFAULT_TURN_TIMEOUT)
}

fn parse_timeout_ms(key: &str, fallback: Duration) -> Duration {
    std::env::var(key)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .map_or(fallback, Duration::from_millis)
}

fn extract_text(params_json: &str) -> String {
    let Ok(value) = serde_json::from_str::<Value>(params_json) else {
        return params_json.to_string();
    };
    value
        .get("text")
        .and_then(Value::as_str)
        .map_or_else(|| params_json.to_string(), ToString::to_string)
}

fn json_string_at(body: &str, key: &str) -> Option<String> {
    serde_json::from_str::<Value>(body)
        .ok()?
        .get(key)?
        .as_str()
        .map(ToString::to_string)
}

fn display_id(request_id_json: &str) -> String {
    let Ok(value) = serde_json::from_str::<Value>(request_id_json) else {
        return request_id_json.trim_matches('"').to_string();
    };
    match value {
        Value::String(text) => text,
        Value::Number(number) => number.to_string(),
        _ => request_id_json.to_string(),
    }
}

fn claude_decision(result_json: &str) -> PermissionDecisionInput {
    let value = serde_json::from_str::<Value>(result_json).unwrap_or(Value::Null);
    let kind = value
        .get("decision")
        .or_else(|| value.get("outcome"))
        .or_else(|| value.get("kind"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    match kind.as_str() {
        "accept" | "allow" | "approved" | "allowonce" => PermissionDecisionInput::Allow {
            include_updated_permissions: false,
        },
        _ => PermissionDecisionInput::Deny {
            message: "declined".to_string(),
            interrupt: false,
        },
    }
}

fn map_event(payload: &[u8], family: LiveFamily) -> Option<ProviderInbound> {
    let value = serde_json::from_slice::<Value>(payload).ok()?;
    match family {
        LiveFamily::Claude => map_claude_event(&value),
        LiveFamily::Codex | LiveFamily::Acp => map_provider_event(&value),
    }
}

fn map_provider_event(value: &Value) -> Option<ProviderInbound> {
    let kind = value.get("kind")?.as_str()?;
    let payload = value.get("payload").cloned().unwrap_or(Value::Null);
    match kind {
        "notification" => Some(ProviderInbound::Notification {
            method: payload
                .get("method")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            params_json: payload
                .get("params")
                .cloned()
                .unwrap_or_else(|| json!({}))
                .to_string(),
        }),
        "serverRequest" => {
            let id = payload.get("id").cloned().unwrap_or(Value::Null);
            let id_json = payload
                .get("id_json")
                .and_then(Value::as_str)
                .map_or_else(|| id.to_string(), ToString::to_string);
            let id_display = match &id {
                Value::String(text) => text.clone(),
                Value::Number(number) => number.to_string(),
                _ => id_json.clone(),
            };
            Some(ProviderInbound::ServerRequest {
                id_json,
                id_display,
                method: payload
                    .get("method")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                params_json: payload
                    .get("params")
                    .cloned()
                    .unwrap_or_else(|| json!({}))
                    .to_string(),
            })
        }
        "processExited" => Some(ProviderInbound::ProcessExited),
        "protocolError" => Some(ProviderInbound::ProtocolError(
            payload
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("protocol error")
                .to_string(),
        )),
        _ => None,
    }
}

fn map_claude_event(value: &Value) -> Option<ProviderInbound> {
    let kind = value.get("kind")?.as_str()?;
    match kind {
        "processExited" => Some(ProviderInbound::ProcessExited),
        "error" => Some(ProviderInbound::ProtocolError(
            value
                .get("text")
                .or_else(|| value.get("message"))
                .and_then(Value::as_str)
                .unwrap_or("claude error")
                .to_string(),
        )),
        "approvalRequest" => {
            let id = value
                .get("request_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            Some(ProviderInbound::ServerRequest {
                id_json: json!(id).to_string(),
                id_display: id,
                method: "can_use_tool".to_string(),
                params_json: value.to_string(),
            })
        }
        _ => Some(ProviderInbound::Notification {
            method: kind.to_string(),
            params_json: value.to_string(),
        }),
    }
}
