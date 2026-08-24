import Foundation

package protocol FileEditHost {
    func fileExists(path: String) async -> Bool
    func readText(path: String) async throws -> String
    func writeText(path: String, content: String, overwrite: Bool) async throws
}

/// TD-3 §5.3.1/§6.1 (design `docs/designs/textdecode-policy-v2-2026-08-22.md`): an additive
/// capability a `FileEditHost` conformer may ALSO implement to hand `ApplyEditsService` genuinely
/// raw, undecoded bytes instead of a Swift-decoded `String`. `FileEditHost` itself is untouched
/// (round-2 Finding F2) -- `ApplyEditsService` downcasts to this protocol and, when present,
/// prefers it over `readText`, routing to `ApplyEditsComputing`'s raw-bytes overload so Rust's
/// apply-edits handler decodes via `textdecode()` as its own first step (single FFI crossing).
/// Both `DirectHeadlessFileEditHost` (ladder 6, headless `agentry-mcp`) and the GUI's
/// `WorkspaceFileEditHost` conform. Each host remains responsible for stable-read/write-back
/// validation around the raw byte snapshot.
package protocol RawBytesFileEditHost {
    func readRawBytes(path: String) async throws -> Data
}
