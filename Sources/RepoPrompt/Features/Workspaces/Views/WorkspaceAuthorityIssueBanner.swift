import SwiftUI

/// Surfaces a domain-workspace authority failure that would otherwise stay on
/// `WorkspaceManagerViewModel.domainWorkspaceAuthorityIssue` with no UI.
struct WorkspaceAuthorityIssueBanner: View {
    @ObservedObject var workspaceManager: WorkspaceManagerViewModel

    var body: some View {
        if let issue = workspaceManager.domainWorkspaceAuthorityIssue {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = issue.detailText {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(issue.recoveryInstruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if issue.isSessionDismissible {
                        Button {
                            workspaceManager.dismissDomainWorkspaceAuthorityIssue()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .hoverTooltip("Dismiss for this session")
                        .accessibilityLabel("Dismiss workspace authority warning")
                    }
                }
                HStack {
                    Button("Retry") {
                        Task {
                            await workspaceManager.refreshDomainWorkspaceAuthority()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.orange.opacity(0.8), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.orange)
                    .frame(width: 4)
                    .padding(.vertical, 6)
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(issue.message)
        }
    }
}

private extension DomainWorkspaceAuthorityIssue {
    var isSessionDismissible: Bool {
        switch kind {
        case .commandFailure, .projectionFailure:
            true
        case .externalConflict, .degradedReadOnly, .removed:
            false
        }
    }

    var detailText: String? {
        let pieces = [reason, diagnostic].compactMap { value -> String? in
            guard let value, !value.isEmpty, value != message else { return nil }
            return value
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: " — ")
    }
}
