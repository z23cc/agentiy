import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexExecAgentProviderRuntimePreparationTests: XCTestCase {
    func testPrepareUsesRuntimeStateAuthorityAndMapsFailureBeforeMCPBootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExecAgentProviderRuntimePreparationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        // Derived from the product constant rather than written as a literal. This test asserts
        // what happens *after* the version gate, so pinning a number here just means the fixture
        // silently falls behind every runtime rotation and the test starts failing on the gate
        // instead -- which is exactly what 8133e1fa (0.147.0 -> 0.151.0) did to the previous
        // hard-coded "0.149.0".
        let stubVersion = CodexRuntimeAuthority.minimumExternalVersion
        try "#!/bin/sh\necho 'codex \(stubVersion)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let recorder = PreparedRuntimeRecorder()
        let provider = CodexExecAgentProvider(
            config: .init(commandName: executable.path, additionalPathHints: []),
            runtimeStatePreparer: { runtime in
                recorder.record(runtime)
                throw RuntimePreparationFailure.conflict
            }
        )

        do {
            _ = try await provider.prepare()
            XCTFail("prepare must fail when isolated Codex state preparation fails")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertTrue(detail.contains("unable to prepare its isolated Codex state"))
            XCTAssertTrue(detail.contains("projection conflict"))
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.runtime?.source, .externalOverride)
        XCTAssertEqual(recorder.runtime?.executableURL, executable)
    }
}

private enum RuntimePreparationFailure: Error, LocalizedError {
    case conflict

    var errorDescription: String? {
        "projection conflict"
    }
}

private final class PreparedRuntimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRuntime: CodexRuntimeAuthority.Runtime?
    private var recordedCallCount = 0

    func record(_ runtime: CodexRuntimeAuthority.Runtime) {
        lock.lock()
        recordedRuntime = runtime
        recordedCallCount += 1
        lock.unlock()
    }

    var runtime: CodexRuntimeAuthority.Runtime? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRuntime
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallCount
    }
}
