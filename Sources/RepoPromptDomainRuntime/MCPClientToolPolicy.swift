import Foundation

package enum MCPClientTaskRole: String, CaseIterable, Sendable {
    case direct
    case explore
    case engineer
}

package enum MCPClientToolAnnotationProfile: String, CaseIterable, Sendable {
    case canonical
    case suppressReadOnlyHint = "suppress_read_only_hint"
}

package enum MCPClientToolPolicyProfile: String, CaseIterable, Sendable {
    case direct
    case discovery
    case agentModeGenericExplore = "agent_mode_generic_explore"
    case agentModeGenericEngineer = "agent_mode_generic_engineer"
    case agentModeGenericEngineerOrchestrator = "agent_mode_generic_engineer_orchestrator"
    case agentModeClaudeEngineer = "agent_mode_claude_engineer"
    case agentModeCodexEngineer = "agent_mode_codex_engineer"
    case agentModeOpenCodeEngineer = "agent_mode_open_code_engineer"
    case agentModeCursorEngineer = "agent_mode_cursor_engineer"
    case agentModeGrokBuildEngineer = "agent_mode_grok_build_engineer"
}

package struct MCPClientToolPolicyClassification: Sendable {
    package let profile: MCPClientToolPolicyProfile
    package let restrictedCapabilities: Set<MCPToolCapability>
    package let grantedCapabilities: Set<MCPToolCapability>
    package let role: MCPClientTaskRole
    package let allowsAgentExternalControlTools: Bool
    package let annotationProfile: MCPClientToolAnnotationProfile
}

package enum MCPClientToolPolicyCatalog {
    package static let discoveryRestrictedCapabilities: Set<MCPToolCapability> = [
        .conversationSend,
        .agentConversationSend,
        .conversationHelper,
        .fileContentEdit,
        .fileManagement,
        .workspaceMutate,
        .discovery,
        .appSettings,
        .worktreeManage,
        .agentExternalControl,
        .agentExploreControl,
        .agentReasoningControl,
        .statusPublication
    ]

    package static let discoveryGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction
    ]

    package static let agentModeRestrictedCapabilities: Set<MCPToolCapability> = [
        .workspaceMutate,
        .conversationHelper,
        .conversationSend
    ]

    package static let agentModeGenericGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentReasoningControl,
        .statusPublication,
        .agentConversationSend,
        .conversationLog
    ]

    package static let agentModeNativeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .statusPublication,
        .agentConversationSend,
        .conversationLog
    ]

    package static let policyGatedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentReasoningControl,
        .statusPublication,
        .agentConversationSend,
        .conversationLog
    ]

    package static let classifications: [MCPClientToolPolicyProfile: MCPClientToolPolicyClassification] = [
        .direct: .init(
            profile: .direct,
            restrictedCapabilities: [],
            grantedCapabilities: [],
            role: .direct,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .discovery: .init(
            profile: .discovery,
            restrictedCapabilities: discoveryRestrictedCapabilities,
            grantedCapabilities: discoveryGrantedCapabilities,
            role: .direct,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeGenericExplore: .init(
            profile: .agentModeGenericExplore,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeGenericGrantedCapabilities,
            role: .explore,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeGenericEngineer: .init(
            profile: .agentModeGenericEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeGenericGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeGenericEngineerOrchestrator: .init(
            profile: .agentModeGenericEngineerOrchestrator,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeGenericGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: true,
            annotationProfile: .canonical
        ),
        .agentModeClaudeEngineer: .init(
            profile: .agentModeClaudeEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeCodexEngineer: .init(
            profile: .agentModeCodexEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .suppressReadOnlyHint
        ),
        .agentModeOpenCodeEngineer: .init(
            profile: .agentModeOpenCodeEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeCursorEngineer: .init(
            profile: .agentModeCursorEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        ),
        .agentModeGrokBuildEngineer: .init(
            profile: .agentModeGrokBuildEngineer,
            restrictedCapabilities: agentModeRestrictedCapabilities,
            grantedCapabilities: agentModeNativeGrantedCapabilities,
            role: .engineer,
            allowsAgentExternalControlTools: false,
            annotationProfile: .canonical
        )
    ]

    /// The computed form intentionally reads the currently installed runtime catalog. A cached
    /// static set would preserve the generated fixture if a process queried policy before startup.
    package static var policyGatedToolNames: Set<String> {
        policyGatedToolNames(catalog: nil)
    }

    package static func policyGatedToolNames(catalog: MCPDomainCatalogSnapshot?) -> Set<String> {
        toolNames(for: policyGatedCapabilities, catalog: catalog)
    }

    package static func classification(
        for profile: MCPClientToolPolicyProfile
    ) -> MCPClientToolPolicyClassification {
        guard let classification = classifications[profile] else {
            preconditionFailure("Missing MCP client policy classification: \(profile.rawValue)")
        }
        return classification
    }

    package static func hiddenToolNames(for role: MCPClientTaskRole) -> Set<String> {
        hiddenToolNames(for: role, catalog: nil)
    }

    package static func hiddenToolNames(
        for role: MCPClientTaskRole,
        catalog: MCPDomainCatalogSnapshot?
    ) -> Set<String> {
        let exploreControlTools = toolNames(for: [.agentExploreControl], catalog: catalog)
        var exploreCapabilities = discoveryRestrictedCapabilities
        exploreCapabilities.remove(.agentReasoningControl)
        exploreCapabilities.remove(.statusPublication)
        exploreCapabilities.remove(.appSettings)
        exploreCapabilities.insert(.conversationLog)
        exploreCapabilities.insert(.selectionMutate)
        exploreCapabilities.insert(.promptMutate)
        exploreCapabilities.insert(.workspaceRead)
        let agentExternalControlTools = toolNames(for: [.agentExternalControl], catalog: catalog)
        switch role {
        case .direct:
            return exploreControlTools
        case .explore:
            return toolNames(for: exploreCapabilities, catalog: catalog).union(exploreControlTools)
        case .engineer:
            return agentExternalControlTools
        }
    }

    package static func shouldAdvertise(
        toolName: String,
        role: MCPClientTaskRole,
        allowsAgentExternalControlTools: Bool
    ) -> Bool {
        shouldAdvertise(
            toolName: toolName,
            role: role,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            catalog: nil
        )
    }

    package static func shouldAdvertise(
        toolName: String,
        role: MCPClientTaskRole,
        allowsAgentExternalControlTools: Bool,
        catalog: MCPDomainCatalogSnapshot?
    ) -> Bool {
        if role != .explore,
           allowsAgentExternalControlTools,
           toolNames(for: [.agentExternalControl], catalog: catalog).contains(toolName)
        {
            return true
        }
        return !hiddenToolNames(for: role, catalog: catalog).contains(toolName)
    }

    package static func resolvedToolNames(
        for profile: MCPClientToolPolicyProfile
    ) -> [String] {
        resolvedToolNames(for: profile, catalog: nil)
    }

    package static func resolvedToolNames(
        for profile: MCPClientToolPolicyProfile,
        catalog: MCPDomainCatalogSnapshot?
    ) -> [String] {
        let policy = classification(for: profile)
        let restricted = toolNames(for: policy.restrictedCapabilities, catalog: catalog)
        let additional = toolNames(for: policy.grantedCapabilities, catalog: catalog)
        let gated = policyGatedToolNames(catalog: catalog)
        let orderedToolNames = catalog?.orderedToolNames ?? MCPDomainToolCatalog.orderedToolNames
        return orderedToolNames.filter { toolName in
            !restricted.contains(toolName)
                && (!gated.contains(toolName) || additional.contains(toolName))
                && shouldAdvertise(
                    toolName: toolName,
                    role: policy.role,
                    allowsAgentExternalControlTools: policy.allowsAgentExternalControlTools,
                    catalog: catalog
                )
        }
    }

    private static func toolNames(
        for capabilities: Set<MCPToolCapability>,
        catalog: MCPDomainCatalogSnapshot?
    ) -> Set<String> {
        catalog?.toolNames(for: capabilities) ?? MCPDomainToolCatalog.toolNames(for: capabilities)
    }
}
