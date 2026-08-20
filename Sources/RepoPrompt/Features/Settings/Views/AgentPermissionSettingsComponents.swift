//
//  AgentPermissionSettingsComponents.swift
//  RepoPrompt
//
//  Shared UI pieces used by the Agent Permissions settings shell and its focused
//  subviews (Direct Agents / Sub-Agents). Keeps the shell file small and keeps the
//  subviews consistent in look without introducing a new aesthetic pass.
//
//  SEARCH-HELPER: Agent Permissions Components, secure storage banner,
//  capability row, capability chip, related settings link, risk badge,
//  settings group box, agent permissions spacing
//
//  Related:
//  - Shell:    /RepoPrompt/Views/Settings/AgentPermissionsSettingsView.swift
//  - Direct:   /RepoPrompt/Views/Settings/AgentDirectProviderPermissionsView.swift
//  - Sub:      /RepoPrompt/Views/Settings/AgentSubagentPolicySettingsView.swift
//

import SwiftUI

// MARK: - Layout constants

/// Shared spacing/width constants derived from macOS Settings UX guidance
/// (`docs/research/macos-settings-window-ux-best-practices-2026-04-18.md`).
///
/// - `contentMaxWidth`: preferred readable max width for the detail column.
/// - `sectionSpacing`: vertical space between top-level sections.
/// - `groupInsets`: padding inside section GroupBox-style containers.
/// - `controlSpacing`: default VStack spacing between controls inside a group.
///
/// SEARCH-HELPER: AgentPermissionSettingsLayout, 24pt padding, 22pt section spacing,
/// 10pt control spacing, 960pt readable width
enum AgentPermissionSettingsLayout {
    /// Upper bound on the detail column width. Raised from 560 → 960 so the page
    /// flows with the window when the user resizes Settings wider, while still
    /// preventing body text from turning into an ultra-long measure on very wide
    /// displays.
    static let contentMaxWidth: CGFloat = 960
    static let outerPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 22
    static let controlSpacing: CGFloat = 10
    static let groupInsets = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
}

// MARK: - Scope

/// In-pane segmented scope shown inside the Agent Permissions settings tab.
///
/// Keeps Agent Permissions as a single `SettingsTab` while giving the user a clear
/// split between direct/top-level CLI provider permissions and sub-agent sandbox
/// override policy.
///
/// SEARCH-HELPER: AgentPermissionSettingsScope, Direct Agents, Sub-Agents segment
enum AgentPermissionSettingsScope: String, CaseIterable, Identifiable {
    case directAgents
    case subagents

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .directAgents:
            "Direct Agents"
        case .subagents:
            "Sub-Agents"
        }
    }
}

// MARK: - Section container

/// Consistent section container used by both Agent Permissions scopes. Gives each
/// logical cluster a title, optional one-line subtitle, and a rounded background —
/// approximating a SwiftUI `GroupBox` while keeping custom copy/link affordances
/// inline with Agent Permissions styling.
///
/// SEARCH-HELPER: AgentPermissionSettingsGroupBox, settings section, settings card
struct AgentPermissionSettingsGroupBox<Content: View>: View {
    let title: String
    let subtitle: String?
    let accent: Color
    let contentSpacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        accent: Color = .secondary,
        contentSpacing: CGFloat = AgentPermissionSettingsLayout.controlSpacing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.contentSpacing = contentSpacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3).bold()
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: contentSpacing) {
                content()
            }
        }
        .padding(AgentPermissionSettingsLayout.groupInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - Risk badge

/// Small pill used next to high-risk permission rows (e.g. Full Access) so risk is
/// scannable without relying on prose. Per the macOS Settings UX research, risk
/// should be visible at a glance without overwhelming the row.
///
/// SEARCH-HELPER: AgentPermissionRiskBadge, risk pill, caution badge, danger badge
struct AgentPermissionRiskBadge: View {
    enum Level {
        case safe
        case caution
        case danger

        var label: String {
            switch self {
            case .safe: "Safe"
            case .caution: "Caution"
            case .danger: "Danger"
            }
        }

        var color: Color {
            switch self {
            case .safe: .green
            case .caution: .orange
            case .danger: .red
            }
        }

        var iconName: String {
            switch self {
            case .safe: "checkmark.shield.fill"
            case .caution: "exclamationmark.triangle.fill"
            case .danger: "exclamationmark.octagon.fill"
            }
        }
    }

    let level: Level
    var label: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.iconName)
                .font(.caption.weight(.semibold))
            Text(label ?? level.label)
                .font(.footnote.weight(.semibold))
        }
        .foregroundColor(level.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(level.color.opacity(0.14))
        .clipShape(Capsule())
        .accessibilityLabel("Risk: \(label ?? level.label)")
    }
}

// MARK: - Secure storage degraded banner

/// Warning banner shown when `AgentPermissionSecureStore` reports a degraded state
/// (read/write/decode failure or unsupported future schema). The copy never
/// exposes raw Keychain identifiers — just the user-facing safety consequence.
///
/// SEARCH-HELPER: Secure Permission Storage Diagnostics, degraded banner,
/// permission storage unavailable, safe defaults warning
struct AgentPermissionSecureStorageDegradedBanner: View {
    @ObservedObject var diagnostics: AgentPermissionStorageDiagnosticsViewModel

    var body: some View {
        if diagnostics.isSecurePermissionStorageDegraded {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.red)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Secure permission storage unavailable")
                            .font(.body).bold()
                            .foregroundColor(.red)
                        Text("Agentry is using safe default permissions until secure storage is available. Permission changes may not persist.")
                            .font(.callout)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = Self.userFacingDetail(for: diagnostics.storageDiagnostics) {
                            Text(detail)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.red.opacity(0.35), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Secure permission storage unavailable. Agentry is using safe default permissions until secure storage is available. Permission changes may not persist.")
        }
    }

    /// Produces a short sanitized summary of the reasons the secure store is degraded.
    /// Deliberately omits raw Keychain/account identifiers so the banner stays safe to
    /// screenshot and share.
    static func userFacingDetail(
        for diagnostics: [AgentPermissionStorageDiagnostic]
    ) -> String? {
        guard !diagnostics.isEmpty else { return nil }
        var reasons: [String] = []
        var seen: Set<String> = []
        for diagnostic in diagnostics {
            guard let reason = userFacingReason(for: diagnostic.kind) else { continue }
            if seen.insert(reason).inserted {
                reasons.append(reason)
            }
        }
        guard !reasons.isEmpty else { return nil }
        return "Reason: \(reasons.joined(separator: "; "))."
    }

    private static func userFacingReason(for kind: AgentPermissionStorageDiagnostic.Kind) -> String? {
        switch kind {
        case .keychainReadFailed:
            "secure storage could not be read"
        case .keychainWriteFailed:
            "a recent permission change could not be saved securely"
        case .keychainInteractionNotAllowed:
            "secure storage requires user approval and was not accessed during a noninteractive permission check"
        case .keychainAuthenticationFailed:
            "secure storage authentication was denied or cancelled"
        case .decodeFailed:
            "stored permissions could not be decoded"
        case .unsupportedFutureSchema:
            "stored permissions were written by a newer version"
        }
    }
}

// MARK: - Capability row / chip

/// Compact capability row showing a provider's current capability summary. Used by both
/// the editable direct-agent rows and the read-only Safe Managed preview rows. Editable
/// behavior is orchestrated by the caller through the `trailingContent` / `expansion`
/// closures to keep this component stateless.
///
/// SEARCH-HELPER: Agent Permission capability row, provider row, capability summary
struct AgentPermissionCapabilityRow<Trailing: View, Expansion: View>: View {
    let summary: AgentPermissionCapabilitySummary
    let canExpand: Bool
    let isExpanded: Bool
    let onToggleExpansion: (() -> Void)?
    @ViewBuilder let trailingContent: () -> Trailing
    @ViewBuilder let expansion: () -> Expansion

    init(
        summary: AgentPermissionCapabilitySummary,
        canExpand: Bool = false,
        isExpanded: Bool = false,
        onToggleExpansion: (() -> Void)? = nil,
        @ViewBuilder trailingContent: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder expansion: @escaping () -> Expansion = { EmptyView() }
    ) {
        self.summary = summary
        self.canExpand = canExpand
        self.isExpanded = isExpanded
        self.onToggleExpansion = onToggleExpansion
        self.trailingContent = trailingContent
        self.expansion = expansion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tappable zone: header + at-a-glance chips + warnings. Pulling the tap
            // gesture up to this wrapper (instead of just the header HStack) means any
            // click inside the collapsed card toggles expansion — matching user
            // expectations for a card-style disclosure. The expansion content below
            // sits outside this wrapper so its Pickers/Toggles handle their own taps.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: summary.isAvailable ? "circle.fill" : "circle.dashed")
                        .font(.system(size: 10))
                        .foregroundColor(summary.isAvailable ? .green : .secondary)
                    Text(summary.providerName)
                        .font(.body).bold()
                    if let risk = riskLevel, summary.isAvailable {
                        AgentPermissionRiskBadge(level: risk)
                    }
                    Spacer(minLength: 8)
                    if !summary.isAvailable {
                        Text("Not connected")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    trailingContent()
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15), value: isExpanded)
                    }
                }

                // Collapsed card shows two at-a-glance lines — sandbox/permission level
                // and third-party MCP status. Tool toggles (Bash, search, per-server MCP)
                // live inside the expanded Tools & Runtime Options section so the
                // collapsed card stays readable and signals the top-level risk posture
                // without repeating every knob. Hidden entirely for disconnected
                // providers because summarising an effective policy we aren't using
                // adds noise rather than value.
                if summary.isAvailable {
                    VStack(alignment: .leading, spacing: 5) {
                        AgentPermissionCapabilityChip(icon: "lock.shield", text: summary.fileMutation)
                        AgentPermissionCapabilityChip(icon: "network", text: summary.externalMCP)
                    }

                    ForEach(summary.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.footnote)
                            Text(warning)
                                .font(.footnote)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpand else { return }
                onToggleExpansion?()
            }

            if canExpand, isExpanded {
                Divider()
                    .padding(.vertical, 4)
                expansion()
                    .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    /// Heuristic risk classification based on capability summary fields. Keeps the UI
    /// scannable without introducing a new backend signal. Warnings or explicit
    /// "Danger"/"YOLO" phrasing escalate to `danger`; "Full Access"/"Auto-Accept"
    /// phrasing reads as `caution`.
    private var riskLevel: AgentPermissionRiskBadge.Level? {
        if containsDangerKeyword(summary.shell) || containsDangerKeyword(summary.fileMutation) {
            return .danger
        }
        if !summary.warnings.isEmpty {
            return .danger
        }
        if containsCautionKeyword(summary.fileMutation)
            || containsCautionKeyword(summary.shell)
        {
            return .caution
        }
        return nil
    }

    private func containsCautionKeyword(_ value: String) -> Bool {
        // Deliberately conservative to avoid false positives on copy like
        // "not allowed" / "disallowed". Only explicit high-risk phrasing qualifies.
        let needles = ["full access", "auto-accept"]
        let lowered = value.lowercased()
        return needles.contains { lowered.contains($0) }
    }

    private func containsDangerKeyword(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.contains("danger") || lowered.contains("yolo")
    }
}

/// Compact labelled capability line used inside `AgentPermissionCapabilityRow`.
struct AgentPermissionCapabilityChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .center)
            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Related settings link row

/// Single related-settings link used in the Agent Permissions footer. Points at a
/// separate Settings tab so users understand that MCP Tools and Workspace Approvals
/// stay distinct from Agent Permissions.
struct AgentPermissionRelatedLinkRow: View {
    let icon: String
    let title: String
    let detail: String
    let tab: SettingsTab
    let onNavigate: ((SettingsTab) -> Void)?

    var body: some View {
        Button {
            onNavigate?(tab)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 22, alignment: .center)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body).bold()
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onNavigate == nil)
    }
}
