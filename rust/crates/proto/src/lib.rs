//! Versioned Agentry payload contract ownership.

#![forbid(unsafe_code)]

pub mod agent_host;
mod envelope;
mod error;
mod mcp_catalog;

pub use envelope::{
    DEFAULT_MAXIMUM_COLLECTION_ITEMS, DEFAULT_MAXIMUM_STRING_BYTES, DecodeLimits, Envelope,
    HEADER_BYTES, MAGIC, MAXIMUM_ENVELOPE_BYTES, MAXIMUM_PAYLOAD_BYTES, PayloadKind,
};
pub use error::DecodeError;
pub use mcp_catalog::{
    MCP_CATALOG_VERSION, MCP_DEFINITION_SCHEMA_VERSION, MCP_TOOL_COUNT, MCP_TOOL_ORDER,
    McpCatalogError, McpCatalogV1, McpToolAdmissionClassV1, McpToolAnnotationsV1,
    McpToolDefinitionV1, McpToolLimitsV1, McpToolOperationIdentityV1, McpToolOperationInputV1,
    McpToolOperationNormalizationV1, McpToolOperationPolicyV1, McpToolRegistrationScopeV1,
    McpToolResourceScopeV1, McpToolScopeV1, mcp_catalog_canonical_bytes, mcp_catalog_digest,
    mcp_catalog_v1, mcp_tool_definition_v1, mcp_tool_operation_identity_v1,
};

/// Frozen Phase 0 envelope schema version.
pub const ENVELOPE_SCHEMA_VERSION: u16 = 1;

/// Frozen agent-host-v1 wire protocol version (ADR-0011 P2); see [`agent_host`].
pub const AGENT_HOST_PROTOCOL_VERSION: u32 = agent_host::PROTOCOL_VERSION;
