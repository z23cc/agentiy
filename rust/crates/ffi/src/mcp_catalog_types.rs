// P8 MCP catalog FFI records are kept in a separate source file so the generated
// UniFFI surface remains easy to audit against the language-neutral proto record.
use agentry_proto as proto;

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
    pub tools: Vec<CoreMcpToolDefinitionV1>,
}

impl From<&proto::McpToolDefinitionV1> for CoreMcpToolDefinitionV1 {
    fn from(tool: &proto::McpToolDefinitionV1) -> Self {
        let input_schema_json = serde_json::to_string(&tool.input_schema)
            .expect("canonical MCP schema values are serializable");
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
                    normalization: serde_json::to_value(policy.normalization)
                        .expect("normalization is serializable")
                        .as_str()
                        .expect("normalization is a string")
                        .to_owned(),
                });
        Self {
            name: tool.name.clone(),
            description: tool.description.clone(),
            input_schema_json,
            title: tool.annotations.title.clone(),
            read_only_hint: tool.annotations.read_only_hint,
            destructive_hint: tool.annotations.destructive_hint,
            idempotent_hint: tool.annotations.idempotent_hint,
            open_world_hint: tool.annotations.open_world_hint,
            enabled_by_default: tool.enabled_by_default,
            scope: serde_json::to_value(tool.scope)
                .expect("scope is serializable")
                .as_str()
                .expect("scope is a string")
                .to_owned(),
            registration_scopes: tool
                .registration_scopes
                .iter()
                .map(|scope| {
                    serde_json::to_value(scope)
                        .expect("scope is serializable")
                        .as_str()
                        .unwrap()
                        .to_owned()
                })
                .collect(),
            capability: tool.capability.clone(),
            admission_class: serde_json::to_value(tool.admission_class)
                .expect("admission class is serializable")
                .as_str()
                .expect("admission class is a string")
                .to_owned(),
            operation_policy,
            limits: CoreMcpToolLimitsV1 {
                connection_lane: tool.limits.connection_lane,
                resource_lease: tool.limits.resource_lease,
                resource_scope: tool.limits.resource_scope.map(|scope| {
                    serde_json::to_value(scope)
                        .expect("resource scope is serializable")
                        .as_str()
                        .unwrap()
                        .to_owned()
                }),
            },
            shared_read: tool.shared_read,
        }
    }
}
