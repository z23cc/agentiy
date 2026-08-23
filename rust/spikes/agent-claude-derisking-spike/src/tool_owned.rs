//! E-P6-1(c): host-owned-tool-name predicate, ported as data.
//!
//! Byte-for-byte port of `MCPIntegrationHelper.isRepoPromptToolName` /
//! `resolveRepoPromptToolName` (`Sources/RepoPrompt/Infrastructure/MCP/MCPIntegrationHelper.swift`
//! `:36`, `:159-209`, `:229-231`), which is the closure design section 2.1 / contract section 8
//! decides "becomes data": the server name plus the canonical alias set are passed once at
//! session-open and evaluated Rust-side with no FFI crossing on the hot tool-result path.
//!
//! This is a pure function with no I/O and no host coupling beyond the two constants below,
//! matching the Swift source's own claim that `resolveRepoPromptToolName`'s only external input
//! is `repoPromptMCPServerName`.

/// `RepoPromptMCPServerConfiguration.defaultServerName`
/// (`Sources/RepoPrompt/Infrastructure/MCP/RepoPromptMCPServerConfiguration.swift:16`).
pub const REPO_PROMPT_MCP_SERVER_NAME: &str = "RepoPromptCE";

/// `MCPIntegrationHelper.repoPromptToolNames` (`MCPIntegrationHelper.swift:37-66`), 27 entries.
pub const REPO_PROMPT_TOOL_NAMES: &[&str] = &[
    "ask_user",
    "ask_user_question",
    "get_file_tree",
    "file_search",
    "read_file",
    "get_code_structure",
    "apply_edits",
    "file_actions",
    "manage_selection",
    "prompt",
    "workspace_context",
    "ask_oracle",
    "oracle_send",
    "oracle_utils",
    "oracle_chat_log",
    "history",
    "git",
    "bind_context",
    "manage_workspaces",
    "context_builder",
    "share_thoughts",
    "wait_for_next_user_instruction",
    "agent_explore",
    "agent_run",
    "agent_manage",
    "set_status",
    "app_settings",
];

/// Mirrors `MCPIntegrationHelper.trimmedLowercasedToolName` (`:159-164`).
fn trimmed_lowercased(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_lowercase())
    }
}

/// Mirrors `MCPIntegrationHelper.stripFunctionsPrefix` (`:166-172`). Note this is a `while` loop
/// (repeated stripping) -- unlike the explicit-server-prefix strip below, which strips at most once.
fn strip_functions_prefix(mut s: String) -> String {
    while let Some(rest) = s.strip_prefix("functions.") {
        s = rest.to_string();
    }
    s
}

/// Mirrors `MCPIntegrationHelper.stripExplicitRepoPromptPrefix` (`:174-186`). Checked in this
/// exact order; the first match wins and the strip happens **once** (not a loop) -- an input
/// carrying two nested explicit prefixes only has the outer one removed, by design/port fidelity.
fn strip_explicit_repoprompt_prefix(raw: &str) -> (String, bool) {
    let server = REPO_PROMPT_MCP_SERVER_NAME.to_lowercase();
    let prefixes = [
        format!("mcp__{server}__"),
        format!("mcp_{server}__"),
        format!("{server}__"),
        format!("{server}_"),
    ];
    for prefix in &prefixes {
        if let Some(stripped) = raw.strip_prefix(prefix.as_str()) {
            return (stripped.to_string(), true);
        }
    }
    (raw.to_string(), false)
}

/// Mirrors `MCPIntegrationHelper.canonicalRepoPromptToolAlias` (`:188-196`).
fn canonical_repoprompt_tool_alias(normalized_name: &str) -> Option<String> {
    if !REPO_PROMPT_TOOL_NAMES.contains(&normalized_name) {
        return None;
    }
    match normalized_name {
        "ask_user" | "ask_user_question" => Some("ask_user".to_string()),
        other => Some(other.to_string()),
    }
}

/// Resolution result, mirroring the Swift `RepoPromptToolNameResolution` struct (`:114-118`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolNameResolution {
    pub normalized_name: String,
    pub canonical_name: Option<String>,
    pub has_explicit_server_prefix: bool,
}

/// Mirrors `MCPIntegrationHelper.resolveRepoPromptToolName(_:)` (`:198-209`). Swift's signature
/// takes `String?`; `None` here corresponds to a `nil` raw name.
pub fn resolve_repoprompt_tool_name(raw_name: Option<&str>) -> Option<ToolNameResolution> {
    let lowered = trimmed_lowercased(raw_name?)?;
    let without_functions = strip_functions_prefix(lowered);
    let (normalized_name, explicit) = strip_explicit_repoprompt_prefix(&without_functions);
    let canonical_name = canonical_repoprompt_tool_alias(&normalized_name);
    let has_explicit_server_prefix = explicit && canonical_name.is_some();
    Some(ToolNameResolution {
        normalized_name,
        canonical_name,
        has_explicit_server_prefix,
    })
}

/// Mirrors `MCPIntegrationHelper.isRepoPromptToolName(_ rawName: String) -> Bool`
/// (`:229-231`) -- the exact predicate `ClaudeSDKNDJSONTranslator.swift:53-56`'s
/// `treatsToolResultErrorsAsHostOwned` closure is wired to today, and the predicate contract
/// section 8 / design section 2.1 decide becomes Rust-side data with no FFI crossing.
pub fn is_repoprompt_tool_name(raw_name: &str) -> bool {
    resolve_repoprompt_tool_name(Some(raw_name))
        .and_then(|r| r.canonical_name)
        .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(serde::Deserialize)]
    struct FixtureCase {
        input: String,
        expected: bool,
        #[allow(dead_code)]
        note: String,
    }

    #[derive(serde::Deserialize)]
    struct Fixture {
        #[allow(dead_code)]
        #[serde(rename = "schemaVersion")]
        schema_version: u32,
        cases: Vec<FixtureCase>,
    }

    fn fixture_path() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("fixtures")
            .join("host-owned-tool-name-cases-v1.json")
    }

    /// E-P6-1(c) differential's Rust arm: assert the ported predicate agrees with the curated,
    /// hand-verified expectation for every case in the shared fixture (the same fixture the Swift
    /// arm in `HostOwnedToolNamePredicateDifferentialTests.swift` asserts the real
    /// `MCPIntegrationHelper.isRepoPromptToolName` against). Full alias-table coverage (27/27
    /// canonical names) plus adversarial prefixed/normalized/`functions.`-prefixed forms.
    #[test]
    fn rust_port_matches_curated_fixture() {
        let raw = std::fs::read_to_string(fixture_path())
            .unwrap_or_else(|e| panic!("failed to read fixture at {:?}: {e}", fixture_path()));
        let fixture: Fixture = serde_json::from_str(&raw).expect("fixture must be valid JSON");
        assert!(!fixture.cases.is_empty(), "fixture must be non-empty");

        let mut mismatches = Vec::new();
        for case in &fixture.cases {
            let actual = is_repoprompt_tool_name(&case.input);
            if actual != case.expected {
                mismatches.push(format!(
                    "input={:?} note={:?} expected={} actual={}",
                    case.input, case.note, case.expected, actual
                ));
            }
        }
        assert!(
            mismatches.is_empty(),
            "E-P6-1(c) mismatch(es) against curated fixture:\n{}",
            mismatches.join("\n")
        );
    }

    #[test]
    fn fixture_covers_full_alias_table() {
        let raw = std::fs::read_to_string(fixture_path()).unwrap();
        let fixture: Fixture = serde_json::from_str(&raw).unwrap();
        let inputs: std::collections::HashSet<&str> =
            fixture.cases.iter().map(|c| c.input.as_str()).collect();
        for name in REPO_PROMPT_TOOL_NAMES {
            assert!(
                inputs.contains(name),
                "fixture is missing exact-canonical coverage for {name:?}"
            );
        }
    }
}
