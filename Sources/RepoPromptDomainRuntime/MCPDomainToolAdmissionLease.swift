import Foundation

/// Identity-carrying resource lease returned by the domain host. The release operation is
/// idempotent so transport cancellation, provider failure, and normal completion may race safely.
package final class MCPDomainToolAdmissionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (() -> Void)?
    package let catalogDigest: String?
    package let toolName: String

    package init(
        toolName: String,
        catalogDigest: String?,
        releaseAction: @escaping () -> Void
    ) {
        self.toolName = toolName
        self.catalogDigest = catalogDigest
        self.releaseAction = releaseAction
    }

    @discardableResult
    package func release() -> Bool {
        let action: (() -> Void)? = lock.withLock {
            defer { releaseAction = nil }
            return releaseAction
        }
        action?()
        return action != nil
    }

    deinit {
        release()
    }
}
