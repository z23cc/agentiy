import Foundation

/// One matching line in a file.
///
/// `lineNumber` is **0-based** (the first line in the file is numbered `0`).
/// MCP tool output converts to 1-based line numbers for display (`file_search`),
/// while internal indexing stays 0-based for array operations.
package struct SearchMatch: Hashable, Codable, Sendable {
    package let filePath: String
    package let lineNumber: Int
    package let lineText: String
    package let contextBefore: [String]?
    package let contextAfter: [String]?

    package init(
        filePath: String,
        lineNumber: Int,
        lineText: String,
        contextBefore: [String]? = nil,
        contextAfter: [String]? = nil
    ) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

/// Search strategy requested by the caller.
package enum SearchMode: String, Codable, Sendable {
    case auto, path, content, both
}
