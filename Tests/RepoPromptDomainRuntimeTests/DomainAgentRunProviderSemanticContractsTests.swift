import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// Cross-provider semantic closure tests. Provider adapters can differ in wire events, but they
/// must reduce the same typed termination facts to the same Domain terminal outcome.
final class DomainAgentRunProviderSemanticContractsTests: XCTestCase {
    func testCanonicalTerminationSignalsHaveStableResolution() {
        let cases: [(DomainAgentRunProviderTerminationSignal, DomainAgentRunProviderSemanticResolution)] = [
            (.completed(assistantText: "done"), .terminal(.completed(assistantText: "done"))),
            (.cancelled(assistantText: "stopped"), .terminal(.cancelled(assistantText: "stopped"))),
            (.startupFailure(assistantText: "not configured"), .terminal(.failedWithoutClassification(assistantText: "not configured"))),
            (.providerFailure(assistantText: "provider rejected", reason: nil), .terminal(.failedWithoutClassification(assistantText: "provider rejected"))),
            (.providerFailure(assistantText: "provider rejected", reason: .agentError), .terminal(.failed(assistantText: "provider rejected", reason: .agentError))),
            (.timeout(assistantText: "deadline"), .terminal(.failed(assistantText: "deadline", reason: .timeout))),
            (.processExited(assistantText: "exit 1"), .terminal(.failed(assistantText: "exit 1", reason: .processCrash))),
            (.transportClosed(assistantText: "closed"), .terminal(.failed(assistantText: "closed", reason: .processCrash))),
            (.unexpectedEnd(assistantText: "EOF"), .terminal(.failed(assistantText: "EOF", reason: .processCrash))),
            (.superseded, .superseded)
        ]

        for (signal, expected) in cases {
            XCTAssertEqual(
                DomainAgentRunProviderSemanticAuthority.resolve(signal),
                expected,
                "signal: \(signal)"
            )
            XCTAssertEqual(
                DomainAgentRunProviderSemanticAuthority.isTerminal(signal),
                signal != .superseded,
                "terminal flag: \(signal)"
            )
        }
    }

    func testExplicitFailureReasonWinsOverDeferredClassification() {
        let signal = DomainAgentRunProviderTerminationSignal.providerFailure(
            assistantText: "timed out while waiting",
            reason: .agentError
        )

        XCTAssertEqual(
            DomainAgentRunProviderSemanticAuthority.outcome(signal),
            .failed(assistantText: "timed out while waiting", reason: .agentError)
        )
    }

    func testTransportAndTimeoutFactsNeverDependOnDisplayText() {
        XCTAssertEqual(
            DomainAgentRunProviderSemanticAuthority.outcome(.timeout(assistantText: "completed successfully")),
            .failed(assistantText: "completed successfully", reason: .timeout)
        )
        XCTAssertEqual(
            DomainAgentRunProviderSemanticAuthority.outcome(.transportClosed(assistantText: "all good")),
            .failed(assistantText: "all good", reason: .processCrash)
        )
    }

    func testExecuteProviderPreservesTypedOutcomeAndTrace() async {
        let signals: [DomainAgentRunProviderExecutionResult] = [
            .completed(assistantText: "one"),
            .cancelled(assistantText: "two"),
            .failed(signal: .timeout(assistantText: "three")),
            .failed(signal: .processExited(assistantText: "four")),
            .superseded
        ]

        for signal in signals {
            let report = await DomainAgentRunExecutionCore.executeProvider {
                signal
            }
            switch signal {
            case let .completed(text):
                XCTAssertEqual(report.result, .terminal(.completed(assistantText: text)))
                XCTAssertEqual(report.trace, [.executionStarted, .terminalOutcomeProduced(.completed)])
            case let .cancelled(text):
                XCTAssertEqual(report.result, .terminal(.cancelled(assistantText: text)))
                XCTAssertEqual(report.trace, [.executionStarted, .terminalOutcomeProduced(.cancelled)])
            case let .failed(providerSignal):
                let expected = DomainAgentRunProviderSemanticAuthority.outcome(providerSignal)
                XCTAssertEqual(report.result, expected.map(DomainAgentRunExecutionResult.terminal))
                XCTAssertEqual(report.trace, [.executionStarted, .terminalOutcomeProduced(.failed)])
            case .superseded:
                XCTAssertEqual(report.result, .superseded)
                XCTAssertEqual(report.trace, [.executionStarted, .executionSuperseded])
            }
        }
    }

    func testExecuteProviderCancellationAndUnknownThrowRemainSafe() async {
        let cancelled = await DomainAgentRunExecutionCore.executeProvider {
            throw CancellationError()
        }
        XCTAssertEqual(cancelled.result, .terminal(.cancelled()))
        XCTAssertEqual(cancelled.trace, [.executionStarted, .terminalOutcomeProduced(.cancelled)])

        let failed = await DomainAgentRunExecutionCore.executeProvider(
            failureText: { _ in "unclassified provider failure" }
        ) {
            throw ProviderSemanticFixtureError.failed
        }
        XCTAssertEqual(
            failed.result,
            .terminal(.failedWithoutClassification(assistantText: "unclassified provider failure"))
        )
    }

    private enum ProviderSemanticFixtureError: Error {
        case failed
    }
}
