import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class HeadlessMCPDomainRuntimeM0ContractTests: XCTestCase {
    func testCanonicalCatalogActionsPoliciesAndDependenciesMatchFrozenManifest() async throws {
        let manifest = try loadJSONObject("Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json")
        let catalog = try dictionary(manifest, key: "catalog")
        let globals = try strings(catalog, key: "global_tools")
        let windows = try strings(catalog, key: "window_tools")
        let allTools = globals + windows

        XCTAssertEqual(globals, MCPGlobalToolName.orderedToolNames)
        XCTAssertEqual(windows, MCPAppToolGroup.orderedToolNames)
        XCTAssertEqual(allTools.count, 27)
        XCTAssertEqual(Set(allTools).count, allTools.count)

        let actionFixtures = try stringArrays(catalog, key: "actions")
        let actionlessFixtures = try dictionariesByKey(catalog, key: "actionless_tools")
        XCTAssertEqual(Set(actionFixtures.keys).union(actionlessFixtures.keys), Set(allTools))
        XCTAssertTrue(Set(actionFixtures.keys).isDisjoint(with: actionlessFixtures.keys))
        XCTAssertTrue(actionFixtures.values.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(actionFixtures.values.reduce(0) { $0 + $1.count }, 88)
        XCTAssertEqual(try integer(catalog, key: "canonical_discriminated_action_count"), 88)
        XCTAssertEqual(actionlessFixtures.count, try integer(catalog, key: "actionless_tool_count"))

        let window = makeWindowWithoutAutoStart()
        addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
        }
        let liveTools = await window.mcpServer.windowMCPTools
        XCTAssertEqual(liveTools.map(\.name), windows)
        for tool in liveTools {
            if let actionless = actionlessFixtures[tool.name] {
                let properties = try schemaProperties(for: tool)
                let required = try schemaRequiredProperties(for: tool)
                XCTAssertEqual(required, try strings(actionless, key: "required_properties"), tool.name)
                XCTAssertNil(properties["op"], tool.name)
                XCTAssertNil(properties["action"], tool.name)
                continue
            }
            let expected = try XCTUnwrap(actionFixtures[tool.name], tool.name)
            let properties = try schemaProperties(for: tool)
            if tool.name == MCPWindowToolName.applyEdits {
                XCTAssertNotNil(properties["rewrite"])
                XCTAssertNotNil(properties["search"])
                XCTAssertNotNil(properties["edits"])
                XCTAssertEqual(expected, ["rewrite", "single_replace", "multiple_edits"])
                continue
            }
            let discriminator = properties["op"] ?? properties["action"]
            let object = try XCTUnwrap(discriminator?.objectValue, tool.name)
            let actual = try XCTUnwrap(object["enum"]?.arrayValue?.compactMap(\.stringValue), tool.name)
            XCTAssertEqual(actual, expected, tool.name)
        }

        let policy = try dictionary(manifest, key: "policy")
        let admissionFixture = try stringArrays(policy, key: "admission")
        let actualAdmission = Dictionary(grouping: MCPToolAdmissionPolicy.classifications) { $0.value.rawValue }
            .mapValues { Set($0.map(\.key)) }
        XCTAssertEqual(actualAdmission, admissionFixture.mapValues(Set.init))

        let executionFixture = try stringArrays(policy, key: "execution")
        var actualExecution: [String: Set<String>] = [:]
        for toolName in allTools {
            let contract = try XCTUnwrap(MCPToolExecutionContractCatalog.contract(for: toolName), toolName)
            let kind = switch contract.kind {
            case .bounded: "bounded"
            case .longSynchronousCancellable: "long_synchronous"
            case .lifecycleManagedCancellable: "lifecycle_managed"
            case .interactiveCancellable: "interactive"
            case .workspaceLifecycleCancellable: "workspace_lifecycle"
            }
            actualExecution[kind, default: []].insert(toolName)
        }
        XCTAssertEqual(actualExecution, executionFixture.mapValues(Set.init))

        let profiles = try stringArrays(policy, key: "advertisement_profiles")
        XCTAssertEqual(
            Set(DiscoverMCPToolPolicy.restrictedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["discover_restricted_capabilities"]))
        )
        XCTAssertEqual(
            Set(DiscoverMCPToolPolicy.grantedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["discover_granted_capabilities"]))
        )
        XCTAssertEqual(
            Set(AgentModeMCPToolPolicy.restrictedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["agent_mode_restricted_capabilities"]))
        )
        XCTAssertEqual(
            Set(AgentModeMCPToolPolicy.grantedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["agent_mode_generic_granted_capabilities"]))
        )
        XCTAssertEqual(Set(AgentModeMCPToolPolicy.claudeNativeGrantedCapabilities.map(\.externalName)), try Set(XCTUnwrap(profiles["agent_mode_claude_granted_capabilities"])))
        XCTAssertEqual(Set(AgentModeMCPToolPolicy.codexNativeGrantedCapabilities.map(\.externalName)), try Set(XCTUnwrap(profiles["agent_mode_codex_granted_capabilities"])))
        XCTAssertEqual(Set(AgentModeMCPToolPolicy.openCodeGrantedCapabilities.map(\.externalName)), try Set(XCTUnwrap(profiles["agent_mode_open_code_granted_capabilities"])))
        XCTAssertEqual(Set(AgentModeMCPToolPolicy.cursorGrantedCapabilities.map(\.externalName)), try Set(XCTUnwrap(profiles["agent_mode_cursor_granted_capabilities"])))
        XCTAssertEqual(
            Set(MCPPolicyGatedTools.gatedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["policy_gated_capabilities"]))
        )

        let capabilityFixtures = try stringArrays(policy, key: "tool_capabilities")
        XCTAssertEqual(Set(capabilityFixtures.keys), Set(allTools))
        for tool in allTools {
            XCTAssertEqual(
                Set(MCPToolCapabilities.capabilities(for: tool).map(\.externalName)),
                try Set(XCTUnwrap(capabilityFixtures[tool])),
                tool
            )
        }

        let annotationProfiles = try stringDictionary(policy, key: "client_annotation_profiles")
        XCTAssertEqual(
            annotationProfiles,
            Dictionary(uniqueKeysWithValues: MCPClientToolPolicyProfile.allCases.map { profile in
                (profile.rawValue, MCPClientToolPolicyCatalog.classification(for: profile).annotationProfile.rawValue)
            })
        )

        let resolvedProfiles = try stringArrays(policy, key: "resolved_tool_policy_projection")
        XCTAssertEqual(resolvedProfiles["direct"], resolvedAdvertisedTools(allTools: allTools))
        XCTAssertEqual(
            resolvedProfiles["discovery"],
            resolvedAdvertisedTools(
                allTools: allTools,
                restricted: DiscoverMCPToolPolicy.restrictedTools,
                additional: DiscoverMCPToolPolicy.grantedTools
            )
        )
        XCTAssertEqual(
            resolvedProfiles["agent_mode_generic_explore"],
            resolvedAdvertisedTools(
                allTools: allTools,
                restricted: AgentModeMCPToolPolicy.restrictedTools,
                additional: AgentModeMCPToolPolicy.grantedTools,
                role: .explore
            )
        )
        XCTAssertEqual(
            resolvedProfiles["agent_mode_generic_engineer"],
            resolvedAdvertisedTools(
                allTools: allTools,
                restricted: AgentModeMCPToolPolicy.restrictedTools,
                additional: AgentModeMCPToolPolicy.grantedTools,
                role: .engineer
            )
        )
        XCTAssertEqual(
            resolvedProfiles["agent_mode_generic_engineer_orchestrator"],
            resolvedAdvertisedTools(
                allTools: allTools,
                restricted: AgentModeMCPToolPolicy.restrictedTools,
                additional: AgentModeMCPToolPolicy.grantedTools,
                role: .engineer,
                allowsAgentExternalControlTools: true
            )
        )
        let nativeProfiles: [(String, Set<String>)] = [
            ("agent_mode_claude_engineer", AgentModeMCPToolPolicy.claudeNativeGrantedTools),
            ("agent_mode_codex_engineer", AgentModeMCPToolPolicy.codexNativeGrantedTools),
            ("agent_mode_open_code_engineer", AgentModeMCPToolPolicy.openCodeGrantedTools),
            ("agent_mode_cursor_engineer", AgentModeMCPToolPolicy.cursorGrantedTools)
        ]
        for (name, granted) in nativeProfiles {
            XCTAssertEqual(
                resolvedProfiles[name],
                resolvedAdvertisedTools(
                    allTools: allTools,
                    restricted: AgentModeMCPToolPolicy.restrictedTools,
                    additional: granted,
                    role: .engineer
                ),
                name
            )
        }
    }

    private func loadJSONObject(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: RepoRoot.url().appendingPathComponent(relativePath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], relativePath)
    }

    private func dictionary(_ object: [String: Any], key: String) throws -> [String: Any] {
        try XCTUnwrap(object[key] as? [String: Any], key)
    }

    private func strings(_ object: [String: Any], key: String) throws -> [String] {
        try XCTUnwrap(object[key] as? [String], key)
    }

    private func stringArrays(_ object: [String: Any], key: String) throws -> [String: [String]] {
        try XCTUnwrap(object[key] as? [String: [String]], key)
    }

    private func stringDictionary(_ object: [String: Any], key: String) throws -> [String: String] {
        try XCTUnwrap(object[key] as? [String: String], key)
    }

    private func dictionariesByKey(_ object: [String: Any], key: String) throws -> [String: [String: Any]] {
        try XCTUnwrap(object[key] as? [String: [String: Any]], key)
    }

    private func integer(_ object: [String: Any], key: String) throws -> Int {
        try XCTUnwrap((object[key] as? NSNumber)?.intValue, key)
    }

    private func schemaProperties(for tool: RepoPromptApp.Tool) throws -> [String: Value] {
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue, tool.name)
        return try XCTUnwrap(schema["properties"]?.objectValue, tool.name)
    }

    private func schemaRequiredProperties(for tool: RepoPromptApp.Tool) throws -> [String] {
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue, tool.name)
        return schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func resolvedAdvertisedTools(
        allTools: [String],
        restricted: Set<String> = [],
        additional: Set<String> = [],
        role: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false
    ) -> [String] {
        allTools.filter { tool in
            !restricted.contains(tool)
                && (!MCPPolicyGatedTools.names.contains(tool) || additional.contains(tool))
                && AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: tool,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: allowsAgentExternalControlTools
                )
        }
    }

    private func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }
}
