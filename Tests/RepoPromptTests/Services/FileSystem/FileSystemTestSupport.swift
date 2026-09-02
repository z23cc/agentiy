import Foundation

struct FileSystemTemporaryRoots {
    private var roots: [URL] = []

    mutating func makeRoot(suiteName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(suiteName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    mutating func removeAll() {
        for url in roots {
            try? FileManager.default.removeItem(at: url)
        }
        roots.removeAll()
    }
}

enum FileSystemTestSupport {
    static func write(_ content: String, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
