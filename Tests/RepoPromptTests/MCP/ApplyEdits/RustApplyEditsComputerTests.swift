import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

final class RustApplyEditsComputerTests: XCTestCase {
    func testProductionComputerRoutesNormalizedRequestThroughRustBatchSeam() async throws {
        let probe = RustApplyEditsComputerProbe()
        let computer = RustApplyEditsComputer { request in
            await probe.record(request)
            return CoreApplyEditsBatchResultV1(subjects: [
                CoreApplyEditsSubjectResultV1(
                    updatedText: "let value = 2\n",
                    byteEdits: [],
                    chunks: [],
                    editsRequested: 1,
                    editsApplied: 1,
                    status: .success,
                    outcomes: nil,
                    stats: nil,
                    note: nil,
                    unifiedDiff: nil,
                    toolCardUnifiedDiff: nil
                )
            ])
        }
        let request = ApplyEditsRequest(
            path: "Sources/File.swift",
            mode: .single(search: "1", replace: "2", replaceAll: false),
            verbose: true
        )

        let result = try await computer.apply(
            request: request,
            to: "let value = 1\n",
            options: .init(includeToolCardUnifiedDiff: true)
        )

        XCTAssertEqual(result.updatedText, "let value = 2\n")
        let recordedRequest = await probe.request
        let coreRequest = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(coreRequest.contractVersion, CoreApplyEditsBatchRequestV1.contractVersion)
        XCTAssertEqual(coreRequest.subjects.count, 1)
        let subject = try XCTUnwrap(coreRequest.subjects.first)
        XCTAssertEqual(subject.pathLabel, "Sources/File.swift")
        XCTAssertEqual(String(data: subject.originalUTF8, encoding: .utf8), "let value = 1\n")
        XCTAssertTrue(subject.verbose)
        XCTAssertTrue(subject.includeToolCardUnifiedDiff)
        guard case let .single(operation) = subject.mode else {
            return XCTFail("Expected the production adapter to send a Rust single-edit subject")
        }
        XCTAssertEqual(operation, .init(search: "1", replacement: "2", replaceAll: false))
    }
}

private actor RustApplyEditsComputerProbe {
    private(set) var request: CoreApplyEditsBatchRequestV1?

    func record(_ request: CoreApplyEditsBatchRequestV1) {
        self.request = request
    }
}
