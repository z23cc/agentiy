import SwiftUI

/// Unified settings surface that hosts both Copy and Chat preset management under
/// a single "Workflow Presets" tab. A scope picker toggles between Copy and Chat
/// scopes; each embedded list reuses the existing `CopyPresetsSettingsView` /
/// `ChatPresetsSettingsView` (and therefore the existing `CopyPresetManager` /
/// `ChatPresetManager` storage, built-ins, overrides, and visibility behavior).
///
/// This is a view-level composition, not a model-level merge: `CopyPreset` and
/// `ChatPreset` continue to be resolved through their existing managers, and all
/// prompt-building call sites keep operating on the same typed configs they use
/// today. A deeper unified `WorkflowPreset` model / adapter migration (plan
/// Phase P2) is intentionally deferred.
///
/// Related:
/// - Copy list/editor: /RepoPrompt/Views/Settings/CopyPresetsSettingsView.swift
/// - Chat list/editor: /RepoPrompt/Views/Settings/ChatPresetsSettingsView.swift
/// - Backing stores:   /RepoPrompt/ViewModels/CopyPresetManager.swift,
///                     /RepoPrompt/ViewModels/ChatPresetManager.swift
/// - Settings routing: /RepoPrompt/Views/Settings/SettingsView.swift (`SettingsTab.workflowPresets`)
///
/// SEARCH-HELPER: Workflow Presets, unified presets, copy chat preset merge, settings tab
struct WorkflowPresetsSettingsView: View {
    @ObservedObject var promptViewModel: PromptViewModel

    @State private var scope: Scope

    /// Scope filter values surfaced in the segmented picker. Kept intentionally
    /// narrow (Copy / Chat) while the underlying models remain separate; the
    /// plan allows widening to an "All"/per-scope set once the unified
    /// `WorkflowPreset` model lands.
    enum Scope: String, CaseIterable, Identifiable {
        case copy
        case chat

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .copy: "Copy"
            case .chat: "Chat"
            }
        }

        var subtitle: String {
            switch self {
            case .copy:
                "Templates for the copy-to-paste workflow."
            case .chat:
                "Presets for the built-in Agentry chat UI."
            }
        }

        var iconName: String {
            switch self {
            case .copy: "doc.on.clipboard"
            case .chat: "bubble.left.and.bubble.right"
            }
        }
    }

    init(promptViewModel: PromptViewModel, initialScope: Scope = .copy) {
        self.promptViewModel = promptViewModel
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 12)
                .padding(.top, 12)

            scopeBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)

            Divider()

            Group {
                switch scope {
                case .copy:
                    CopyPresetsSettingsView(promptViewModel: promptViewModel, embedded: true)
                case .chat:
                    ChatPresetsSettingsView(promptViewModel: promptViewModel, embedded: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(scope) // Reset inner view state (search, filter) when scope changes
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Workflow Presets")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Reusable presets for the copy-to-paste and built-in chat workflows. Each preset bundles a system prompt (where applicable), code-map / file-tree / git-diff options, and stored prompts. These don't affect Agent Mode.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Scope picker

    private var scopeBar: some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { s in
                    Label(s.title, systemImage: s.iconName).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            Text(scope.subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }
}
