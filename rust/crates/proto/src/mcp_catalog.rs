//! Canonical MCP/tool catalog authority (P9).
//!
//! The JSON artifact under `catalog/` is the only authored catalog. Consumers in
//! Swift and other languages are generated projections of this record; they must
//! never reconstruct ordering, schemas, or operation policy independently.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::sync::OnceLock;

pub const MCP_CATALOG_VERSION: u16 = 1;
pub const MCP_DEFINITION_SCHEMA_VERSION: u16 = 1;
pub const MCP_TOOL_COUNT: usize = 27;

/// The wire order is part of the MCP compatibility contract. Keep this list explicit so a
/// catalog edit cannot silently reorder tool advertisement while retaining the same set.
pub const MCP_TOOL_ORDER: [&str; MCP_TOOL_COUNT] = [
    "app_settings",
    "bind_context",
    "manage_workspaces",
    "manage_selection",
    "file_actions",
    "get_code_structure",
    "get_file_tree",
    "read_file",
    "file_search",
    "workspace_context",
    "prompt",
    "apply_edits",
    "oracle_utils",
    "ask_oracle",
    "oracle_send",
    "oracle_chat_log",
    "git",
    "manage_worktree",
    "context_builder",
    "ask_user",
    "agent_explore",
    "agent_run",
    "agent_manage",
    "share_thoughts",
    "set_status",
    "wait_for_next_user_instruction",
    "history",
];

const CATALOG_JSON: &str = include_str!("../catalog/mcp_catalog_v1.json");

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct McpCatalogV1 {
    pub catalog_version: u16,
    pub definition_schema_version: u16,
    pub tools: Vec<McpToolDefinitionV1>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct McpToolDefinitionV1 {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
    pub annotations: McpToolAnnotationsV1,
    pub enabled_by_default: bool,
    pub scope: McpToolScopeV1,
    pub registration_scopes: Vec<McpToolRegistrationScopeV1>,
    pub capability: String,
    pub admission_class: McpToolAdmissionClassV1,
    pub operation_policy: Option<McpToolOperationPolicyV1>,
    pub limits: McpToolLimitsV1,
    pub shared_read: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct McpToolAnnotationsV1 {
    pub title: Option<String>,
    pub read_only_hint: Option<bool>,
    pub destructive_hint: Option<bool>,
    pub idempotent_hint: Option<bool>,
    pub open_world_hint: Option<bool>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum McpToolScopeV1 {
    Application,
    Window,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum McpToolRegistrationScopeV1 {
    Application,
    Window,
    Standalone,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum McpToolAdmissionClassV1 {
    Exclusive,
    Control,
    SmallRead,
    FileRead,
    GitRead,
    FileSearch,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct McpToolOperationPolicyV1 {
    pub argument_key: String,
    pub operations: Vec<String>,
    pub aliases: std::collections::BTreeMap<String, String>,
    pub default_operation: Option<String>,
    pub normalization: McpToolOperationNormalizationV1,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum McpToolOperationNormalizationV1 {
    Exact,
    Lowercased,
    TrimmedLowercased,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct McpToolLimitsV1 {
    pub connection_lane: u32,
    pub resource_lease: Option<u32>,
    pub resource_scope: Option<McpToolResourceScopeV1>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum McpToolResourceScopeV1 {
    Application,
    Window,
    Repository,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct McpToolOperationIdentityV1 {
    pub canonical_tool: String,
    pub normalized_operation: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum McpToolOperationInputV1 {
    Missing,
    Value(String),
    Malformed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct McpCatalogError {
    pub message: String,
}

impl std::fmt::Display for McpCatalogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for McpCatalogError {}

static CATALOG: OnceLock<Result<McpCatalogV1, McpCatalogError>> = OnceLock::new();

pub fn mcp_catalog_v1() -> Result<&'static McpCatalogV1, McpCatalogError> {
    CATALOG
        .get_or_init(|| {
            let catalog: McpCatalogV1 =
                serde_json::from_str(CATALOG_JSON).map_err(|error| McpCatalogError {
                    message: format!("invalid embedded MCP catalog: {error}"),
                })?;
            validate_catalog(&catalog)?;
            Ok(catalog)
        })
        .as_ref()
        .map_err(Clone::clone)
}

/// Returns a recursively key-sorted, compact JSON representation. Arrays retain authored order;
/// object-key order is canonicalized at every depth, including input schemas and operation maps.
pub fn mcp_catalog_canonical_bytes() -> Result<Vec<u8>, McpCatalogError> {
    let catalog = mcp_catalog_v1()?;
    let value = serde_json::to_value(catalog).map_err(|error| McpCatalogError {
        message: format!("failed to serialize MCP catalog: {error}"),
    })?;
    let mut bytes = Vec::new();
    write_canonical_json(&value, &mut bytes).map_err(|error| McpCatalogError {
        message: format!("failed to canonicalize MCP catalog: {error}"),
    })?;
    Ok(bytes)
}

pub fn mcp_catalog_digest() -> Result<String, McpCatalogError> {
    let bytes = mcp_catalog_canonical_bytes()?;
    let digest = Sha256::digest(bytes);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub fn mcp_tool_definition_v1(
    name: &str,
) -> Result<Option<&'static McpToolDefinitionV1>, McpCatalogError> {
    Ok(mcp_catalog_v1()?
        .tools
        .iter()
        .find(|tool| tool.name == name))
}

pub fn mcp_tool_operation_identity_v1(
    tool_name: &str,
    input: McpToolOperationInputV1,
) -> Result<McpToolOperationIdentityV1, McpCatalogError> {
    let tool = match mcp_tool_definition_v1(tool_name)? {
        Some(tool) => tool,
        None => {
            return Ok(McpToolOperationIdentityV1 {
                canonical_tool: "unknown".to_owned(),
                normalized_operation: "unknown".to_owned(),
            });
        }
    };
    let Some(policy) = &tool.operation_policy else {
        return Ok(McpToolOperationIdentityV1 {
            canonical_tool: tool.name.clone(),
            normalized_operation: "call".to_owned(),
        });
    };
    let candidate = match input {
        McpToolOperationInputV1::Missing => match &policy.default_operation {
            Some(default) => default.clone(),
            None => return Ok(unknown_operation_identity(&tool.name)),
        },
        McpToolOperationInputV1::Malformed => return Ok(unknown_operation_identity(&tool.name)),
        McpToolOperationInputV1::Value(value) => match policy.normalization {
            McpToolOperationNormalizationV1::Exact => value,
            McpToolOperationNormalizationV1::Lowercased => value.to_lowercase(),
            McpToolOperationNormalizationV1::TrimmedLowercased => value.trim().to_lowercase(),
        },
    };
    let canonical = policy
        .operations
        .iter()
        .find(|operation| operation.as_str() == candidate)
        .cloned()
        .or_else(|| {
            policy
                .aliases
                .get(&candidate)
                .filter(|operation| policy.operations.contains(operation))
                .cloned()
        });
    Ok(canonical
        .map(|operation| McpToolOperationIdentityV1 {
            canonical_tool: tool.name.clone(),
            normalized_operation: operation,
        })
        .unwrap_or_else(|| unknown_operation_identity(&tool.name)))
}

fn unknown_operation_identity(tool_name: &str) -> McpToolOperationIdentityV1 {
    McpToolOperationIdentityV1 {
        canonical_tool: tool_name.to_owned(),
        normalized_operation: "unknown".to_owned(),
    }
}

fn write_canonical_json(
    value: &serde_json::Value,
    output: &mut Vec<u8>,
) -> Result<(), serde_json::Error> {
    match value {
        serde_json::Value::Null => output.extend_from_slice(b"null"),
        serde_json::Value::Bool(value) => {
            output.extend_from_slice(if *value { b"true" } else { b"false" })
        }
        serde_json::Value::Number(value) => output.extend_from_slice(value.to_string().as_bytes()),
        serde_json::Value::String(value) => {
            output.extend_from_slice(serde_json::to_string(value)?.as_bytes())
        }
        serde_json::Value::Array(values) => {
            output.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index != 0 {
                    output.push(b',');
                }
                write_canonical_json(value, output)?;
            }
            output.push(b']');
        }
        serde_json::Value::Object(values) => {
            let mut keys: Vec<&String> = values.keys().collect();
            keys.sort_unstable();
            output.push(b'{');
            for (index, key) in keys.into_iter().enumerate() {
                if index != 0 {
                    output.push(b',');
                }
                output.extend_from_slice(serde_json::to_string(key)?.as_bytes());
                output.push(b':');
                write_canonical_json(&values[key], output)?;
            }
            output.push(b'}');
        }
    }
    Ok(())
}

fn validate_catalog(catalog: &McpCatalogV1) -> Result<(), McpCatalogError> {
    if catalog.catalog_version != MCP_CATALOG_VERSION
        || catalog.definition_schema_version != MCP_DEFINITION_SCHEMA_VERSION
    {
        return Err(McpCatalogError {
            message: format!(
                "unsupported MCP catalog version {}/{}",
                catalog.catalog_version, catalog.definition_schema_version
            ),
        });
    }
    if catalog.tools.len() != MCP_TOOL_COUNT {
        return Err(McpCatalogError {
            message: format!(
                "MCP catalog must contain {MCP_TOOL_COUNT} tools, found {}",
                catalog.tools.len()
            ),
        });
    }
    let mut names = BTreeSet::new();
    for (index, tool) in catalog.tools.iter().enumerate() {
        if tool.name.trim().is_empty() || !names.insert(tool.name.clone()) {
            return Err(McpCatalogError {
                message: format!(
                    "MCP catalog contains duplicate/empty tool name {:?}",
                    tool.name
                ),
            });
        }
        if MCP_TOOL_ORDER[index] != tool.name {
            return Err(McpCatalogError {
                message: format!(
                    "MCP catalog order mismatch at index {index}: expected {:?}, found {:?}",
                    MCP_TOOL_ORDER[index], tool.name
                ),
            });
        }
        if !tool.enabled_by_default {
            return Err(McpCatalogError {
                message: format!("MCP tool {} is not enabled by default", tool.name),
            });
        }
        if tool
            .input_schema
            .get("type")
            .and_then(serde_json::Value::as_str)
            != Some("object")
        {
            return Err(McpCatalogError {
                message: format!("MCP tool {} schema must be an object", tool.name),
            });
        }
        validate_metadata(tool)?;
        if let Some(policy) = &tool.operation_policy {
            validate_operation_policy(tool, policy)?;
        }
    }
    Ok(())
}

fn validate_metadata(tool: &McpToolDefinitionV1) -> Result<(), McpCatalogError> {
    if tool.capability.trim().is_empty() || !KNOWN_CAPABILITIES.contains(&tool.capability.as_str())
    {
        return Err(McpCatalogError {
            message: format!("MCP tool {} has unknown capability", tool.name),
        });
    }
    if tool.limits.connection_lane > 8
        || tool.limits.resource_lease == Some(0)
        || !matches!(
            tool.scope,
            McpToolScopeV1::Application | McpToolScopeV1::Window
        )
    {
        return Err(McpCatalogError {
            message: format!("MCP tool {} has invalid scope or limits", tool.name),
        });
    }
    let expected_scopes = match tool.scope {
        McpToolScopeV1::Application => vec![McpToolRegistrationScopeV1::Application],
        McpToolScopeV1::Window => vec![
            McpToolRegistrationScopeV1::Window,
            McpToolRegistrationScopeV1::Standalone,
        ],
    };
    if tool.registration_scopes != expected_scopes {
        return Err(McpCatalogError {
            message: format!("MCP tool {} has invalid registration scopes", tool.name),
        });
    }
    Ok(())
}

fn validate_operation_policy(
    tool: &McpToolDefinitionV1,
    policy: &McpToolOperationPolicyV1,
) -> Result<(), McpCatalogError> {
    let Some(properties) = tool.input_schema.get("properties") else {
        return Err(McpCatalogError {
            message: format!("MCP tool {} operation schema has no properties", tool.name),
        });
    };
    if properties.get(&policy.argument_key).is_none()
        || policy.argument_key.trim().is_empty()
        || policy.operations.is_empty()
        || policy
            .operations
            .iter()
            .any(|operation| operation.trim().is_empty())
        || policy.operations.iter().collect::<BTreeSet<_>>().len() != policy.operations.len()
    {
        return Err(McpCatalogError {
            message: format!("MCP tool {} has invalid operation policy", tool.name),
        });
    }
    if let Some(default) = &policy.default_operation {
        if !policy
            .operations
            .iter()
            .any(|operation| operation == default)
        {
            return Err(McpCatalogError {
                message: format!("MCP tool {} has invalid default operation", tool.name),
            });
        }
    }
    for (alias, operation) in &policy.aliases {
        if alias.trim().is_empty() || !policy.operations.iter().any(|item| item == operation) {
            return Err(McpCatalogError {
                message: format!("MCP tool {} has invalid operation alias", tool.name),
            });
        }
    }
    Ok(())
}

const KNOWN_CAPABILITIES: [&str; 23] = [
    "app_settings",
    "workspace_mutate",
    "selection_mutate",
    "file_management",
    "structural_explore",
    "file_read",
    "file_search",
    "workspace_read",
    "prompt_mutate",
    "conversation_helper",
    "agent_conversation_send",
    "conversation_send",
    "conversation_log",
    "git_read",
    "worktree_manage",
    "discovery",
    "user_interaction",
    "agent_explore_control",
    "agent_external_control",
    "agent_reasoning_control",
    "agent_session_control",
    "file_content_edit",
    "history_read",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_catalog_has_stable_shape_and_digest() {
        let catalog = mcp_catalog_v1().expect("embedded catalog");
        assert_eq!(catalog.tools.len(), MCP_TOOL_COUNT);
        assert_eq!(
            catalog
                .tools
                .iter()
                .map(|tool| tool.name.as_str())
                .collect::<Vec<_>>(),
            MCP_TOOL_ORDER
        );
        let bytes = mcp_catalog_canonical_bytes().expect("canonical catalog");
        assert!(serde_json::from_slice::<serde_json::Value>(&bytes).is_ok());
        let digest = mcp_catalog_digest().expect("catalog digest");
        assert_eq!(digest.len(), 64);
        assert!(
            digest
                .chars()
                .all(|character| character.is_ascii_hexdigit())
        );
        assert_eq!(digest, digest.to_lowercase());
    }

    #[test]
    fn operation_aliases_and_registration_scopes_are_authoritative() {
        let file_actions = mcp_tool_definition_v1("file_actions")
            .expect("catalog")
            .expect("file_actions");
        let policy = file_actions.operation_policy.as_ref().expect("policy");
        assert_eq!(policy.aliases.get("rename"), Some(&"move".to_owned()));
        let identity = mcp_tool_operation_identity_v1(
            "file_actions",
            McpToolOperationInputV1::Value("RENAME".to_owned()),
        )
        .expect("operation identity");
        assert_eq!(identity.canonical_tool, "file_actions");
        assert_eq!(identity.normalized_operation, "move");
        assert_eq!(
            file_actions.registration_scopes,
            vec![
                McpToolRegistrationScopeV1::Window,
                McpToolRegistrationScopeV1::Standalone
            ]
        );
        let read_file = mcp_tool_definition_v1("read_file")
            .expect("catalog")
            .expect("read_file");
        assert_eq!(
            read_file.registration_scopes,
            vec![
                McpToolRegistrationScopeV1::Window,
                McpToolRegistrationScopeV1::Standalone
            ]
        );
    }
}
