import Foundation

/// P8 fence-claim of the existing `DomainWorkspaceAuthorityLease` flock.
///
/// Production writers are `--backend auto` → headless (`MCPDomainRuntime`) when no
/// GUI-shaped holder exists. This type is the observe / optional host-claim seam:
/// it never invents a second lock, never steals `mode == "app"`, and releases on
/// explicit shutdown.
package enum AgentSessionHostWorkspaceClaim: Equatable, Sendable {
    case claimed(DomainWorkspaceAuthorityLeaseOwner)
    case refusedGUI(DomainWorkspaceAuthorityLeaseOwner)
    case contended(observedOwner: DomainWorkspaceAuthorityLeaseOwner?)
    case failed(reason: String)
}

package actor AgentSessionHostWorkspaceLease {
    private let configuration: DomainRuntimeConfiguration
    private let lease: DomainWorkspaceAuthorityLease

    package init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity
    ) {
        self.configuration = configuration
        lease = DomainWorkspaceAuthorityLease(configuration: configuration, identity: identity)
    }

    /// Peek the kernel lock without retaining it or rewriting owner metadata.
    package static func observe(
        configuration: DomainRuntimeConfiguration
    ) -> DomainWorkspaceAuthorityLeaseObservation {
        DomainWorkspaceAuthorityLease.observe(
            scope: DomainWorkspaceAuthorityLeaseScope(configuration: configuration)
        )
    }

    /// Observe the same physical Workspaces root the GUI / default headless session uses.
    /// Honours `AGENTRY_APPLICATION_SUPPORT_ROOT` and optional `GlobalCustomStorageURL`.
    package static func observeApplicationSupport(
        workspaceStorageDirectory: URL? = nil
    ) -> DomainWorkspaceAuthorityLeaseObservation {
        observe(configuration: applicationSupportConfiguration(
            workspaceStorageDirectory: workspaceStorageDirectory
        ))
    }

    package static func applicationSupportConfiguration(
        workspaceStorageDirectory: URL? = nil
    ) -> DomainRuntimeConfiguration {
        let paths = AgentSessionHostPaths.resolve(protocolVersion: 1)
        let custom = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace: URL = if let workspaceStorageDirectory {
            workspaceStorageDirectory
        } else if let custom, !custom.isEmpty {
            URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            paths.workspacesRoot
        }
        return DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "agent-session-host",
            storageDirectory: paths.applicationSupportRoot,
            workspaceStorageDirectory: workspace,
            eventDirectory: paths.applicationSupportRoot.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: paths.applicationSupportRoot.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        )
    }

    /// Claim only when the flock is free of a live GUI-shaped holder. Other standalone
    /// holders fail closed (contended).
    package func fenceClaim() async -> AgentSessionHostWorkspaceClaim {
        let observation = Self.observe(configuration: configuration)
        if let gui = observation.liveGUIHolder {
            return .refusedGUI(gui)
        }
        switch observation {
        case let .failed(reason):
            return .failed(reason: reason)
        case .unused, .held:
            break
        }
        switch await lease.fenceClaim() {
        case let .held(owner):
            return .claimed(owner)
        case let .contended(observedOwner):
            if let observedOwner, observedOwner.isGUIShaped {
                return .refusedGUI(observedOwner)
            }
            return .contended(observedOwner: observedOwner)
        case let .failed(reason):
            return .failed(reason: reason)
        case .idle, .acquiring, .released:
            return .failed(reason: "canonical_storage_lease_acquisition_incomplete")
        }
    }

    package func release() async {
        await lease.releaseHeld()
    }
}
