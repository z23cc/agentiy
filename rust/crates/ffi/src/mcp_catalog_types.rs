// P9 MCP catalog FFI records are kept in a separate source file so the generated
// UniFFI surface remains easy to audit against the language-neutral proto record.
use crate::errors::CoreError;
use agentry_proto as proto;

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreMcpToolOperationInputV1 {
    Missing,
    Value(String),
    Malformed,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreMcpToolOperationIdentityV1 {
    pub canonical_tool: String,
    pub normalized_operation: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreMcpToolAliasV1 {
    pub alias: String,
    pub canonical_operation: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreMcpToolOperationPolicyV1 {
    pub argument_key: String,
    pub operations: Vec<String>,
    pub aliases: Vec<CoreMcpToolAliasV1>,
    pub default_operation: Option<String>,
    pub normalization: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreMcpToolLimitsV1 {
    pub connection_lane: u32,
    pub resource_lease: Option<u32>,
    pub resource_scope: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreMcpToolDefinitionV1 {
    pub name: String,
    pub description: String,
    /// Canonical compact JSON object for the MCP input schema.
    pub input_schema_json: String,
    pub title: Option<String>,
    pub read_only_hint: Option<bool>,
    pub destructive_hint: Option<bool>,
    pub idempotent_hint: Option<bool>,
    pub open_world_hint: Option<bool>,
    pub enabled_by_default: bool,
    pub scope: String,
    pub registration_scopes: Vec<String>,
    pub capability: String,
    pub admission_class: String,
    pub operation_policy: Option<CoreMcpToolOperationPolicyV1>,
    pub limits: CoreMcpToolLimitsV1,
    pub shared_read: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreMcpToolCatalogV1 {
    pub catalog_version: u16,
    pub definition_schema_version: u16,
    pub digest: String,
    /// Exact bytes used to compute `digest`; consumers must verify before projecting tools.
    pub canonical_catalog_json: Vec<u8>,
    pub tools: Vec<CoreMcpToolDefinitionV1>,
}

impl TryFrom<&proto::McpToolDefinitionV1> for CoreMcpToolDefinitionV1 {
    type Error = CoreError;

    fn try_from(tool: &proto::McpToolDefinitionV1) -> Result<Self, Self::Error> {
        let input_schema_json =
            serde_json::to_string(&tool.input_schema).map_err(|_| CoreError::InvalidArgument)?;
        let operation_policy =
            tool.operation_policy
                .as_ref()
                .map(|policy| CoreMcpToolOperationPolicyV1 {
                    argument_key: policy.argument_key.clone(),
                    operations: policy.operations.clone(),
                    aliases: policy
                        .aliases
                        .iter()
                        .map(|(alias, canonical_operation)| CoreMcpToolAliasV1 {
                            alias: alias.clone(),
                            canonical_operation: canonical_operation.clone(),
                        })
                        .collect(),
                    default_operation: policy.default_operation.clone(),
                    normalization: normalization_name(policy.normalization),
                });
        Ok(Self {
            name: tool.name.clone(),
            description: tool.description.clone(),
            input_schema_json,
            title: tool.annotations.title.clone(),
            read_only_hint: tool.annotations.read_only_hint,
            destructive_hint: tool.annotations.destructive_hint,
            idempotent_hint: tool.annotations.idempotent_hint,
            open_world_hint: tool.annotations.open_world_hint,
            enabled_by_default: tool.enabled_by_default,
            scope: scope_name(tool.scope),
            registration_scopes: tool
                .registration_scopes
                .iter()
                .map(|scope| registration_scope_name(*scope))
                .collect(),
            capability: tool.capability.clone(),
            admission_class: admission_class_name(tool.admission_class),
            operation_policy,
            limits: CoreMcpToolLimitsV1 {
                connection_lane: tool.limits.connection_lane,
                resource_lease: tool.limits.resource_lease,
                resource_scope: tool.limits.resource_scope.map(resource_scope_name),
            },
            shared_read: tool.shared_read,
        })
    }
}

impl TryFrom<(&proto::McpCatalogV1, String, Vec<u8>)> for CoreMcpToolCatalogV1 {
    type Error = CoreError;

    fn try_from(
        (catalog, digest, canonical_catalog_json): (&proto::McpCatalogV1, String, Vec<u8>),
    ) -> Result<Self, Self::Error> {
        Ok(Self {
            catalog_version: catalog.catalog_version,
            definition_schema_version: catalog.definition_schema_version,
            digest,
            canonical_catalog_json,
            tools: catalog
                .tools
                .iter()
                .map(CoreMcpToolDefinitionV1::try_from)
                .collect::<Result<Vec<_>, _>>()?,
        })
    }
}

impl From<CoreMcpToolOperationInputV1> for proto::McpToolOperationInputV1 {
    fn from(value: CoreMcpToolOperationInputV1) -> Self {
        match value {
            CoreMcpToolOperationInputV1::Missing => Self::Missing,
            CoreMcpToolOperationInputV1::Value(value) => Self::Value(value),
            CoreMcpToolOperationInputV1::Malformed => Self::Malformed,
        }
    }
}

fn scope_name(value: proto::McpToolScopeV1) -> String {
    match value {
        proto::McpToolScopeV1::Application => "application",
        proto::McpToolScopeV1::Window => "window",
    }
    .to_owned()
}

fn registration_scope_name(value: proto::McpToolRegistrationScopeV1) -> String {
    match value {
        proto::McpToolRegistrationScopeV1::Application => "application",
        proto::McpToolRegistrationScopeV1::Window => "window",
        proto::McpToolRegistrationScopeV1::Standalone => "standalone",
    }
    .to_owned()
}

fn admission_class_name(value: proto::McpToolAdmissionClassV1) -> String {
    match value {
        proto::McpToolAdmissionClassV1::Exclusive => "exclusive",
        proto::McpToolAdmissionClassV1::Control => "control",
        proto::McpToolAdmissionClassV1::SmallRead => "small_read",
        proto::McpToolAdmissionClassV1::FileRead => "file_read",
        proto::McpToolAdmissionClassV1::GitRead => "git_read",
        proto::McpToolAdmissionClassV1::FileSearch => "file_search",
    }
    .to_owned()
}

fn resource_scope_name(value: proto::McpToolResourceScopeV1) -> String {
    match value {
        proto::McpToolResourceScopeV1::Application => "application",
        proto::McpToolResourceScopeV1::Window => "window",
        proto::McpToolResourceScopeV1::Repository => "repository",
    }
    .to_owned()
}

fn normalization_name(value: proto::McpToolOperationNormalizationV1) -> String {
    match value {
        proto::McpToolOperationNormalizationV1::Exact => "exact",
        proto::McpToolOperationNormalizationV1::Lowercased => "lowercased",
        proto::McpToolOperationNormalizationV1::TrimmedLowercased => "trimmed_lowercased",
    }
    .to_owned()
}
