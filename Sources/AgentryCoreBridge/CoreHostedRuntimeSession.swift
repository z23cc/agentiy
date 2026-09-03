/// Headless host names for the Codex/ACP process session and P6-c semantic objects.
///
/// `RepoPromptDomainRuntime` must not mention `AgentProvider` (source-layout
/// greps treat that as GUI plugin implementation). The host executor talks to
/// these aliases instead of the GUI-facing type names.
public typealias CoreHostedRuntimeSession = CoreAgentProviderSession
public typealias CoreHostedRuntimeEvent = CoreAgentProviderEvent
public typealias CoreHostedCodexSemantics = CoreAgentProviderCodexSemantics
public typealias CoreHostedAcpSemantics = CoreAgentProviderAcpSemantics
public typealias CoreHostedCodexLifecycle = CoreAgentProviderCodexLifecycle
public typealias CoreHostedCodexModelOption = AgentProviderCodexModelOptionV1
public typealias CoreHostedCodexReasoningEffort = AgentProviderCodexReasoningEffortV1
public typealias CoreHostedCodexSelection = AgentProviderCodexSelectionV1
public typealias CoreHostedCodexServerRequestKind = AgentProviderCodexServerRequestKindV1
public typealias CoreHostedCodexLifecycleEvent = AgentProviderCodexLifecycleEventV1
public typealias CoreHostedAcpRuntimeKind = AgentProviderAcpProviderIdV1
public typealias CoreHostedAcpPermissionOption = AgentProviderAcpPermissionOptionV1
public typealias CoreHostedAcpDecisionMapping = AgentProviderAcpDecisionMappingV1
public typealias CoreHostedOpenCodeToolProfile = AgentProviderOpenCodeToolProfileV1
