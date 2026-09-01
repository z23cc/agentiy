import Foundation

/// Creates an empty, real directory to use as a test workspace repo root.
///
/// Tests must not root a workspace at `FileManager.default.currentDirectoryPath`: that is the
/// actual Agentry checkout, so every `createWorkspace` builds a Rust `PathSearchIndex` and
/// populates `inventory_scope` over the whole repository. Measured on a developer machine, one
/// such test took ~26s against the repo root versus 0.26s against an empty temporary root -- a
/// 100x difference that made these suites read as hangs whenever a suite timeout was shorter
/// than (tests x 26s).
enum MCPTestWorkspaceRoot {
    /// Non-throwing so call sites stay a plain expression: SwiftFormat's `hoistTry` rule rejects
    /// an inline `try` inside a `createWorkspace(...)` argument list. A test cannot proceed
    /// without its workspace root, so an unusable temporary directory is a hard stop rather than
    /// a condition worth threading through every caller.
    static func makeEmptyRepoRoot(_ label: String = "workspace") -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agentry-mcp-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("could not create temporary workspace root at \(url.path): \(error)")
        }
        return url.path
    }
}
