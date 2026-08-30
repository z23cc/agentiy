import Foundation

/// Canonical identity used by the domain repository admission coordinator. A linked worktree
/// resolves to its common Git directory, so all checkouts of one repository share one lane.
enum MCPGitRepositoryAdmissionIdentity {
    nonisolated static func key(for checkoutRoot: URL) -> String {
        let standardizedRoot = checkoutRoot.standardizedFileURL
        let repositoryIdentity = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: standardizedRoot)?.commonDir
            ?? standardizedRoot
        return URL(fileURLWithPath: repositoryIdentity.path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .lowercased()
    }
}
