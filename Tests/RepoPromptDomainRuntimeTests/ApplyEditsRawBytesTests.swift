import AgentryCoreBridge
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// TD-3 (`docs/designs/textdecode-policy-v2-2026-08-22.md` §6.1/§5.3.1 mechanism 2/D-6): proves
/// the Swift-side raw-bytes plumbing `DirectHeadlessFileEditHost` (headless `agentry-mcp`,
/// `RepoPromptMCP`) relies on -- `RawBytesFileEditHost`, `ApplyEditsService`'s host-capability
/// dispatch, and `RustApplyEditsComputer`'s raw-bytes construction path / error mapping.
/// `DirectHeadlessFileEditHost` itself is `private` inside `RepoPromptMCP` (an executable
/// target with no dedicated XCTest target), so it cannot be unit-tested directly from here; this
/// exercises the exact mechanism it uses instead, with a fake host and a fake Rust seam.
final class ApplyEditsRawBytesTests: XCTestCase {
    private actor FakeRawBytesHost: FileEditHost, RawBytesFileEditHost {
        private let path: String
        private let bytes: Data
        private(set) var readTextCallCount = 0
        private(set) var readRawBytesCallCount = 0
        private(set) var writtenContent: String?

        init(path: String, bytes: Data) {
            self.path = path
            self.bytes = bytes
        }

        func fileExists(path: String) async -> Bool {
            path == self.path
        }

        func readText(path: String) async throws -> String {
            readTextCallCount += 1
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw ApplyEditsError.invalidParams("not UTF-8")
            }
            return text
        }

        func readRawBytes(path: String) async throws -> Data {
            readRawBytesCallCount += 1
            return bytes
        }

        func writeText(path: String, content: String, overwrite: Bool) async throws {
            writtenContent = content
        }
    }

    /// A `FileEditHost`-only conformer (no `RawBytesFileEditHost`) -- proves GUI apply-edits'
    /// existing `readText`-based path is untouched: `ApplyEditsService` must not call the
    /// raw-bytes overload for a host that doesn't advertise the capability.
    private actor StringOnlyHost: FileEditHost {
        private let path: String
        private let text: String
        private(set) var readTextCallCount = 0

        init(path: String, text: String) {
            self.path = path
            self.text = text
        }

        func fileExists(path: String) async -> Bool {
            path == self.path
        }

        func readText(path: String) async throws -> String {
            readTextCallCount += 1
            return text
        }

        func writeText(path: String, content: String, overwrite: Bool) async throws {}
    }

    private actor RecordingComputer: ApplyEditsComputing, RawBytesApplyEditsComputing {
        private(set) var stringCalls: [String] = []
        private(set) var rawBytesCalls: [Data] = []
        private let rawResult: Result<ApplyEditsResult, Error>
        private let rawOriginalText: String

        init(rawResult: Result<ApplyEditsResult, Error>, rawOriginalText: String = "decoded original") {
            self.rawResult = rawResult
            self.rawOriginalText = rawOriginalText
        }

        func apply(
            request: ApplyEditsRequest,
            to originalText: String,
            options: ApplyEditsExecutionOptions
        ) async throws -> ApplyEditsResult {
            stringCalls.append(originalText)
            return .init(
                updatedText: originalText,
                diffChunks: [],
                unifiedDiff: nil,
                toolCardUnifiedDiff: nil,
                stats: nil,
                note: nil,
                fileCreated: false,
                fileOverwritten: false,
                editsRequested: 0,
                editsApplied: 0,
                status: .success,
                outcomes: nil
            )
        }

        func apply(
            request: ApplyEditsRequest,
            toRawBytes rawBytes: Data,
            options: ApplyEditsExecutionOptions
        ) async throws -> ApplyEditsResult {
            try await applyRawBytes(request: request, rawBytes: rawBytes, options: options).result
        }

        func applyRawBytes(
            request _: ApplyEditsRequest,
            rawBytes: Data,
            options _: ApplyEditsExecutionOptions
        ) async throws -> ApplyEditsRawBytesComputation {
            rawBytesCalls.append(rawBytes)
            switch rawResult {
            case let .success(result):
                return ApplyEditsRawBytesComputation(originalText: rawOriginalText, result: result)
            case let .failure(error):
                throw error
            }
        }
    }

    private static func successResult(text: String) -> ApplyEditsResult {
        .init(
            updatedText: text,
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

    /// D-6: `ApplyEditsService` must prefer `RawBytesFileEditHost.readRawBytes` over
    /// `FileEditHost.readText` when the host offers it, routing through the computer's raw-bytes
    /// overload -- the mechanism `DirectHeadlessFileEditHost` (ladder 6) relies on to hand Rust
    /// genuinely raw, undecoded bytes for a single-crossing `textdecode()`-first apply-edits call.
    func testServicePrefersRawBytesHostOverReadTextWhenBothAreAvailable() async throws {
        let path = "/root/legacy.txt"
        let rawBytes = Data([0x82, 0xA0]) // genuine Shift-JIS, not valid UTF-8
        XCTAssertNil(String(data: rawBytes, encoding: .utf8))
        let host = FakeRawBytesHost(path: path, bytes: rawBytes)
        let computer = RecordingComputer(rawResult: .success(Self.successResult(text: "updated")))
        let service = ApplyEditsService(computer: computer, host: host)

        let result = try await service.run(
            .init(path: path, mode: .rewrite(newText: "updated", onMissing: .error), verbose: false)
        )

        XCTAssertEqual(result.updatedText, "updated")
        let rawCalls = await computer.rawBytesCalls
        let stringCalls = await computer.stringCalls
        XCTAssertEqual(rawCalls, [rawBytes])
        XCTAssertTrue(stringCalls.isEmpty)
        let readRawCount = await host.readRawBytesCallCount
        let readTextCount = await host.readTextCallCount
        XCTAssertEqual(readRawCount, 1)
        XCTAssertEqual(readTextCount, 0, "readText must not run a redundant Swift-side decode once readRawBytes is available")
        let written = await host.writtenContent
        XCTAssertEqual(written, "updated")
    }

    func testPreviewReturnsTheExactRustDecodedOriginalForApprovedWrites() async throws {
        let path = "/root/legacy.txt"
        let rawBytes = Data([0x82, 0xA0])
        let host = FakeRawBytesHost(path: path, bytes: rawBytes)
        let computer = RecordingComputer(
            rawResult: .success(Self.successResult(text: "updated")),
            rawOriginalText: "あ"
        )
        let service = ApplyEditsService(computer: computer, host: host)

        let preview = try await service.preview(
            .init(path: path, mode: .rewrite(newText: "updated", onMissing: .error), verbose: false)
        )

        XCTAssertTrue(preview.exists)
        XCTAssertEqual(preview.originalText, "あ")
        XCTAssertEqual(preview.result.updatedText, "updated")
        let rawCalls = await computer.rawBytesCalls
        XCTAssertEqual(rawCalls, [rawBytes])
        let written = await host.writtenContent
        XCTAssertNil(written)
    }

    /// A custom host that does not conform to `RawBytesFileEditHost` retains the compatibility
    /// path: `ApplyEditsService` falls back to `readText` and the String-based computer overload.
    func testServiceFallsBackToReadTextForAHostWithoutRawBytesSupport() async throws {
        let path = "/root/plain.swift"
        let host = StringOnlyHost(path: path, text: "let x = 1\n")
        let computer = RecordingComputer(rawResult: .success(Self.successResult(text: "let x = 2\n")))
        let service = ApplyEditsService(computer: computer, host: host)

        _ = try await service.run(
            .init(path: path, mode: .rewrite(newText: "let x = 2\n", onMissing: .error), verbose: false)
        )

        let stringCalls = await computer.stringCalls
        let rawCalls = await computer.rawBytesCalls
        XCTAssertEqual(stringCalls, ["let x = 1\n"])
        XCTAssertTrue(rawCalls.isEmpty)
        let readTextCount = await host.readTextCallCount
        XCTAssertEqual(readTextCount, 1)
    }

    /// §5.3.1 mechanism 2 / R8: a lossy raw decode must surface as the distinguishable
    /// `ApplyEditsError.lossyDecodeBlocksWriteBack` case, not a generic internal error, and must
    /// not reach `writeText` -- proves write-back is genuinely refused, not silently lossy.
    func testLossyRawDecodeBlocksWriteBackAndDoesNotReachWriteText() async throws {
        let path = "/root/corrupt.bin"
        let rawBytes = Data([0xFF, 0xFE, 0x00, 0xD8]) // UTF-16 LE BOM + lone high surrogate
        let host = FakeRawBytesHost(path: path, bytes: rawBytes)
        let computer = RecordingComputer(
            rawResult: .failure(ApplyEditsError.lossyDecodeBlocksWriteBack("raw source decoded lossily"))
        )
        let service = ApplyEditsService(computer: computer, host: host)

        do {
            _ = try await service.run(
                .init(path: path, mode: .rewrite(newText: "anything", onMissing: .error), verbose: false)
            )
            XCTFail("expected lossyDecodeBlocksWriteBack to propagate")
        } catch let error as ApplyEditsError {
            guard case let .lossyDecodeBlocksWriteBack(message) = error else {
                XCTFail("expected .lossyDecodeBlocksWriteBack, got \(error)")
                return
            }
            XCTAssertEqual(message, "raw source decoded lossily")
        }
        let written = await host.writtenContent
        XCTAssertNil(written, "write-back must not occur once the raw decode is flagged lossy")
    }

    /// `RustApplyEditsComputer`'s own raw-bytes construction path (used by
    /// `DirectHeadlessFileEditHost` end to end, not just via a fake `ApplyEditsComputing`
    /// conformer): a fake Rust seam that throws `CoreApplyEditsLossyDecodeBlocksWriteBackError`
    /// (the real type `applyEditsBatchV1` throws for this exact case, §5.3.1 mechanism 2's
    /// closing link) must map to `ApplyEditsError.lossyDecodeBlocksWriteBack`, not
    /// `.internalError` -- confirms the error-mapping fix survives the forbidden-file-avoiding
    /// redesign (a dedicated error type instead of a new `CoreComputeError` case).
    func testRustApplyEditsComputerMapsTheDedicatedLossyDecodeErrorType() async throws {
        let computer = RustApplyEditsComputer(applyOperation: { _ in
            throw CoreApplyEditsLossyDecodeBlocksWriteBackError(message: "lossy from the real seam")
        })
        do {
            _ = try await computer.apply(
                request: .init(path: "/root/x.txt", mode: .rewrite(newText: "y", onMissing: .error), verbose: false),
                toRawBytes: Data([0x82, 0xA0]),
                options: .default
            )
            XCTFail("expected lossyDecodeBlocksWriteBack to be thrown")
        } catch let error as ApplyEditsError {
            guard case let .lossyDecodeBlocksWriteBack(message) = error else {
                XCTFail("expected .lossyDecodeBlocksWriteBack, got \(error)")
                return
            }
            XCTAssertEqual(message, "lossy from the real seam")
        }
    }

    /// The default `ApplyEditsComputing.apply(toRawBytes:)` protocol-extension implementation
    /// (for any conformer that doesn't override it) must still behave correctly for valid UTF-8
    /// raw bytes -- proves the extension isn't dead code and degrades safely.
    func testDefaultRawBytesImplementationDecodesValidUTF8AndDelegatesToTheStringOverload() async throws {
        struct StringOnlyComputer: ApplyEditsComputing {
            func apply(
                request: ApplyEditsRequest,
                to originalText: String,
                options: ApplyEditsExecutionOptions
            ) async throws -> ApplyEditsResult {
                ApplyEditsRawBytesTests.successResult(text: originalText + "!")
            }
        }
        let computer = StringOnlyComputer()
        let result = try await computer.apply(
            request: .init(path: "/root/x.txt", mode: .rewrite(newText: "ignored", onMissing: .error), verbose: false),
            toRawBytes: Data("hello".utf8),
            options: .default
        )
        XCTAssertEqual(result.updatedText, "hello!")
    }

    /// The default implementation must fail closed (not silently substitute replacement
    /// characters) for genuinely non-UTF-8 raw bytes handed to a computer that never opted into
    /// raw-bytes support.
    func testDefaultRawBytesImplementationRejectsNonUTF8BytesForAComputerWithoutRawSupport() async throws {
        struct StringOnlyComputer: ApplyEditsComputing {
            func apply(
                request: ApplyEditsRequest,
                to originalText: String,
                options: ApplyEditsExecutionOptions
            ) async throws -> ApplyEditsResult {
                XCTFail("must not reach the string overload for non-UTF-8 raw bytes")
                return ApplyEditsRawBytesTests.successResult(text: originalText)
            }
        }
        let computer = StringOnlyComputer()
        do {
            _ = try await computer.apply(
                request: .init(path: "/root/x.txt", mode: .rewrite(newText: "ignored", onMissing: .error), verbose: false),
                toRawBytes: Data([0x82, 0xA0]),
                options: .default
            )
            XCTFail("expected invalidParams")
        } catch let error as ApplyEditsError {
            guard case .invalidParams = error else {
                XCTFail("expected .invalidParams, got \(error)")
                return
            }
        }
    }
}
