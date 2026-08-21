@testable import RepoPromptApp
import XCTest

final class ApplyEditsServiceTests: XCTestCase {
    func testExistingFilePreviewUsesInjectedComputerWithoutWriting() async throws {
        let computer = ApplyEditsServiceTestComputer()
        let host = ApplyEditsServiceTestHost(text: "before\n")
        let service = ApplyEditsService(computer: computer, host: host)
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .rewrite(newText: "after\n", onMissing: .error),
            verbose: false
        )

        let preview = try await service.preview(request)

        XCTAssertTrue(preview.exists)
        XCTAssertEqual(preview.originalText, "before\n")
        XCTAssertEqual(preview.result.updatedText, "after\n")
        let callCount = await computer.callCount
        let writeCount = await host.writeCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(writeCount, 0)
    }

    func testComputerFailureFailsClosedWithoutWriting() async {
        let computer = ApplyEditsServiceTestComputer(error: .internalError("core unavailable"))
        let host = ApplyEditsServiceTestHost(text: "before\n")
        let service = ApplyEditsService(computer: computer, host: host)
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .rewrite(newText: "after\n", onMissing: .error),
            verbose: false
        )

        do {
            _ = try await service.run(request)
            XCTFail("Expected the compute failure to propagate")
        } catch let error as ApplyEditsError {
            XCTAssertEqual(error, .internalError("core unavailable"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let writeCount = await host.writeCount
        XCTAssertEqual(writeCount, 0)
    }
}

private actor ApplyEditsServiceTestComputer: ApplyEditsComputing {
    private(set) var callCount = 0
    private let error: ApplyEditsError?

    init(error: ApplyEditsError? = nil) {
        self.error = error
    }

    func apply(
        request: ApplyEditsRequest,
        to originalText: String,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult {
        callCount += 1
        if let error { throw error }
        guard case let .rewrite(newText, _) = request.mode else {
            throw ApplyEditsError.internalError("unexpected test mode")
        }
        return ApplyEditsResult(
            updatedText: newText,
            diffChunks: [],
            unifiedDiff: nil,
            toolCardUnifiedDiff: nil,
            stats: nil,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            editsRequested: 1,
            editsApplied: 1,
            status: .success,
            outcomes: nil
        )
    }
}

private actor ApplyEditsServiceTestHost: FileEditHost {
    private let text: String
    private(set) var writeCount = 0

    init(text: String) {
        self.text = text
    }

    func fileExists(path: String) async -> Bool {
        true
    }

    func readText(path: String) async throws -> String {
        text
    }

    func writeText(path: String, content: String, overwrite: Bool) async throws {
        writeCount += 1
    }
}
