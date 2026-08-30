//! Canonical MCP/tool catalog authority (P8).
//!
//! The JSON artifact under `catalog/` is the only authored catalog. Consumers in
//! Swift and other languages are generated projections of this record; they must
//! never reconstruct ordering, schemas, or operation policy independently.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

pub const MCP_CATALOG_VERSION: u16 = 1;
pub const MCP_DEFINITION_SCHEMA_VERSION: u16 = 1;

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

pub fn mcp_catalog_canonical_bytes() -> Result<Vec<u8>, McpCatalogError> {
    let catalog = mcp_catalog_v1()?;
    serde_json::to_vec(catalog).map_err(|error| McpCatalogError {
        message: format!("failed to serialize MCP catalog: {error}"),
    })
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
    if catalog.tools.len() != 27 {
        return Err(McpCatalogError {
            message: format!(
                "MCP catalog must contain 27 tools, found {}",
                catalog.tools.len()
            ),
        });
    }
    let mut names = std::collections::BTreeSet::new();
    for tool in &catalog.tools {
        if tool.name.trim().is_empty() || !names.insert(tool.name.clone()) {
            return Err(McpCatalogError {
                message: format!(
                    "MCP catalog contains duplicate/empty tool name {:?}",
                    tool.name
                ),
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
        if let Some(policy) = &tool.operation_policy {
            if policy.operations.is_empty() || policy.argument_key.trim().is_empty() {
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
                if alias.trim().is_empty()
                    || !policy.operations.iter().any(|item| item == operation)
                {
                    return Err(McpCatalogError {
                        message: format!("MCP tool {} has invalid operation alias", tool.name),
                    });
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_catalog_has_stable_shape_and_digest() {
        let catalog = mcp_catalog_v1().expect("embedded catalog");
        assert_eq!(catalog.tools.len(), 27);
        assert_eq!(catalog.tools[0].name, "app_settings");
        assert_eq!(
            catalog.tools.last().map(|tool| tool.name.as_str()),
            Some("history")
        );
        let digest = mcp_catalog_digest().expect("catalog digest");
        assert_eq!(digest.len(), 64);
        assert!(
            digest
                .chars()
                .all(|character| character.is_ascii_hexdigit())
        );
    }

    #[test]
    fn operation_aliases_and_registration_scopes_are_authoritative() {
        let file_actions = mcp_tool_definition_v1("file_actions")
            .expect("catalog")
            .expect("file_actions");
        let policy = file_actions.operation_policy.as_ref().expect("policy");
        assert_eq!(policy.aliases.get("rename"), Some(&"move".to_owned()));
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
