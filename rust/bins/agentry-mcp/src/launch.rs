//! Host-side launch + credential resolution (ADR-0011 addendum 2026-09-03).
//!
//! Secrets reach this process only via a 0600 `DomainCredentialEnvelope` file
//! (`envelopeID` on `Start`/`SessionSpec`) or the already-present process
//! environment. There is no Keychain path. A missing required credential
//! fail-closes; never Scripted echo.

use std::path::{Path, PathBuf};

use agentry_proto::agent_host::v1::SessionSpec;

use crate::paths::{APPLICATION_SUPPORT_ROOT_ENV, is_safe_path_component};

const LIVE_ENV: &str = "AGENTRY_AGENT_HOST_LIVE";
const PROVIDER_COMMAND_ENV: &str = "AGENTRY_AGENT_HOST_PROVIDER_COMMAND";
const PROVIDER_ARGS_ENV: &str = "AGENTRY_AGENT_HOST_PROVIDER_ARGS";
const CLAUDE_COMMAND_ENV: &str = "AGENTRY_AGENT_HOST_CLAUDE_COMMAND";
const CODEX_COMMAND_ENV: &str = "AGENTRY_AGENT_HOST_CODEX_COMMAND";
const ACP_COMMAND_ENV: &str = "AGENTRY_AGENT_HOST_ACP_COMMAND";
const OPENCODE_COMMAND_ENV: &str = "AGENTRY_AGENT_HOST_OPENCODE_COMMAND";
const CURSOR_COMMAND_ENV: &str = "AGENTRY_AGENT_HOST_CURSOR_COMMAND";
const GROK_COMMAND_ENV: &str = "AGENTRY_AGENT_HOST_GROK_COMMAND";
const WORKING_DIRECTORY_ENV: &str = "AGENTRY_AGENT_HOST_WORKING_DIRECTORY";
const REQUIRE_CREDENTIAL_ENV: &str = "AGENTRY_AGENT_HOST_REQUIRE_CREDENTIAL";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LiveFamily {
    Claude,
    Codex,
    Acp,
}

/// Resolved child launch. `environment` is the already-merged map (never logged).
#[derive(Clone)]
pub struct LaunchSpec {
    pub family: LiveFamily,
    pub command: String,
    pub arguments: Vec<String>,
    pub environment: Vec<(String, String)>,
    pub working_directory: Option<String>,
    pub resume_session_id: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
}

impl std::fmt::Debug for LaunchSpec {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LaunchSpec")
            .field("family", &self.family)
            .field("command", &self.command)
            .field("arguments", &self.arguments)
            .field("environment", &"<redacted>")
            .field("working_directory", &self.working_directory)
            .field("resume_session_id", &self.resume_session_id)
            .field("model", &self.model)
            .field("effort", &self.effort)
            .finish()
    }
}

impl LaunchSpec {
    /// Construct a live spec that cannot spawn. Used to prove fail-closed I/O.
    #[must_use]
    pub fn missing_binary(family: LiveFamily) -> Self {
        Self {
            family,
            command: "/no/such/agentry-agent-host-provider".to_string(),
            arguments: Vec::new(),
            environment: Vec::new(),
            working_directory: None,
            resume_session_id: None,
            model: None,
            effort: None,
        }
    }
}

/// How [`crate::make_provider_transport`] should bind I/O.
#[derive(Debug)]
pub enum TransportChoice {
    Scripted,
    Live(LaunchSpec),
    Unattached { reason: String },
}

#[must_use]
pub fn live_family(provider_id: &str) -> LiveFamily {
    let id = provider_id.to_ascii_lowercase();
    if id.contains("acp") || id.contains("opencode") || id.contains("cursor") || id.contains("grok")
    {
        LiveFamily::Acp
    } else if id.contains("codex") {
        LiveFamily::Codex
    } else {
        LiveFamily::Claude
    }
}

/// Resolve launch info from the process environment and `SessionSpec`.
#[must_use]
pub fn resolve_transport_choice(spec: &SessionSpec) -> TransportChoice {
    resolve_transport_choice_from(
        spec,
        |key| std::env::var(key).ok(),
        std::env::vars().collect(),
    )
}

#[must_use]
pub fn resolve_transport_choice_from(
    spec: &SessionSpec,
    get: impl Fn(&str) -> Option<String>,
    process_vars: Vec<(String, String)>,
) -> TransportChoice {
    let family = live_family(&spec.provider_id);
    let explicit_command = command_override(family, &spec.provider_id, &get);
    let live_flag = matches!(get(LIVE_ENV).as_deref(), Some("1" | "true" | "yes"));
    let envelope_id = spec.credential_envelope_id.trim();
    let wants_live = live_flag || explicit_command.is_some() || !envelope_id.is_empty();
    if !wants_live {
        return TransportChoice::Scripted;
    }
    let envelope_secret = if envelope_id.is_empty() {
        None
    } else {
        match redeem_envelope(
            envelope_id,
            get(APPLICATION_SUPPORT_ROOT_ENV).map(PathBuf::from),
        ) {
            Ok(secret) => Some(secret),
            Err(reason) => {
                return TransportChoice::Unattached { reason };
            }
        }
    };
    let command = explicit_command
        .or_else(|| get(PROVIDER_COMMAND_ENV).filter(|value| !value.trim().is_empty()))
        .unwrap_or_else(|| default_command(&spec.provider_id).to_string());
    if command.trim().is_empty() {
        return TransportChoice::Unattached {
            reason: "live provider command is empty".to_string(),
        };
    }
    let arguments = parse_arguments(get(PROVIDER_ARGS_ENV).as_deref())
        .unwrap_or_else(|| default_arguments(family));
    let working_directory = get(WORKING_DIRECTORY_ENV)
        .filter(|value| !value.is_empty())
        .or_else(|| (!spec.worktree_id.is_empty()).then(|| spec.worktree_id.clone()));
    let mut environment = process_vars;
    overlay_secret(
        &mut environment,
        &spec.provider_id,
        envelope_secret.as_deref(),
    );
    if (requires_credential(&get) || provider_requires_secret(&spec.provider_id))
        && !has_provider_secret(&environment, &spec.provider_id)
    {
        return TransportChoice::Unattached {
            reason: "required provider credential is unavailable".to_string(),
        };
    }
    TransportChoice::Live(LaunchSpec {
        family,
        command,
        arguments,
        environment,
        working_directory,
        resume_session_id: nonempty(&spec.resume_provider_session_id),
        model: nonempty(&spec.model_id),
        effort: nonempty(&spec.reasoning_effort),
    })
}

fn requires_credential(get: &impl Fn(&str) -> Option<String>) -> bool {
    matches!(get(REQUIRE_CREDENTIAL_ENV).as_deref(), Some("1" | "true"))
}

fn provider_requires_secret(provider_id: &str) -> bool {
    matches!(
        provider_id,
        "claudeCodeGLM" | "kimiCode" | "customClaudeCompatible"
    )
}

fn command_override(
    family: LiveFamily,
    provider_id: &str,
    get: &impl Fn(&str) -> Option<String>,
) -> Option<String> {
    let specific = match family {
        LiveFamily::Claude => get(CLAUDE_COMMAND_ENV),
        LiveFamily::Codex => get(CODEX_COMMAND_ENV),
        LiveFamily::Acp => {
            let id = provider_id.to_ascii_lowercase();
            if id.contains("cursor") {
                get(CURSOR_COMMAND_ENV)
            } else if id.contains("grok") {
                get(GROK_COMMAND_ENV)
            } else if id.contains("opencode") {
                get(OPENCODE_COMMAND_ENV)
            } else {
                None
            }
            .or_else(|| get(ACP_COMMAND_ENV))
        }
    };
    specific.filter(|value| !value.trim().is_empty())
}

fn default_command(provider_id: &str) -> &'static str {
    match provider_id {
        "codexExec" => "codex",
        "openCode" => "opencode",
        "cursor" => "cursor-agent",
        "grokBuild" => "grok",
        _ => "claude",
    }
}

fn default_arguments(family: LiveFamily) -> Vec<String> {
    match family {
        LiveFamily::Codex => vec!["app-server".to_string()],
        LiveFamily::Claude | LiveFamily::Acp => Vec::new(),
    }
}

fn parse_arguments(raw: Option<&str>) -> Option<Vec<String>> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(serde_json::Value::Array(items)) = serde_json::from_str::<serde_json::Value>(raw) {
        let parsed: Vec<String> = items
            .into_iter()
            .filter_map(|item| item.as_str().map(ToString::to_string))
            .collect();
        return Some(parsed);
    }
    Some(raw.split_whitespace().map(ToString::to_string).collect())
}

fn nonempty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn overlay_secret(
    environment: &mut Vec<(String, String)>,
    provider_id: &str,
    secret: Option<&str>,
) {
    let Some(secret) = secret.filter(|value| !value.is_empty()) else {
        return;
    };
    let key = secret_env_key(provider_id);
    if let Some((_, value)) = environment.iter_mut().find(|(name, _)| name == key) {
        *value = secret.to_string();
    } else {
        environment.push((key.to_string(), secret.to_string()));
    }
}

fn secret_env_key(provider_id: &str) -> &'static str {
    match provider_id {
        "codexExec" => "OPENAI_API_KEY",
        "openCode" => "OPENCODE_API_KEY",
        "cursor" => "CURSOR_API_KEY",
        "claudeCodeGLM" => "ANTHROPIC_AUTH_TOKEN",
        _ => "ANTHROPIC_API_KEY",
    }
}

fn has_provider_secret(environment: &[(String, String)], provider_id: &str) -> bool {
    let keys: &[&str] = match provider_id {
        "codexExec" => &["OPENAI_API_KEY"],
        "openCode" => &["OPENCODE_API_KEY"],
        "cursor" => &["CURSOR_API_KEY"],
        _ => &["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
    };
    environment
        .iter()
        .any(|(name, value)| keys.contains(&name.as_str()) && !value.is_empty())
}

fn redeem_envelope(
    envelope_id: &str,
    application_support_root: Option<PathBuf>,
) -> Result<String, String> {
    let trimmed = envelope_id.trim().to_ascii_lowercase();
    if !is_safe_path_component(&trimmed) {
        return Err("credential envelope id is invalid".to_string());
    }
    let root = application_support_root.unwrap_or_else(default_application_support_root);
    let path = envelope_directory(&root).join(&trimmed);
    let bytes =
        std::fs::read(&path).map_err(|_| "credential envelope is unavailable".to_string())?;
    if bytes.is_empty() {
        zero_and_remove(&path, 0);
        return Err("credential envelope is unavailable".to_string());
    }
    let secret = String::from_utf8(bytes.clone()).map_err(|_| {
        zero_and_remove(&path, bytes.len());
        "credential envelope is not utf-8".to_string()
    })?;
    zero_and_remove(&path, bytes.len());
    if secret.trim().is_empty() {
        return Err("credential envelope is unavailable".to_string());
    }
    Ok(secret)
}

fn envelope_directory(application_support_root: &Path) -> PathBuf {
    application_support_root
        .join(".agentry-domain-runtime")
        .join("envelopes")
}

fn default_application_support_root() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/Agentry")
}

fn zero_and_remove(path: &Path, len: usize) {
    if len > 0 {
        let _ = std::fs::write(path, vec![0u8; len]);
    }
    let _ = std::fs::remove_file(path);
}
