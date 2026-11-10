import Foundation
import Testing
@testable import TranscriptedLiveCore

@Suite struct LiveCommandExecutionTests {
    private enum Failure: Error { case modelLoad }

    @Test func runtimeFailureReportsNonzeroAfterCleanup() async {
        var events: [String] = []
        let status = await LiveCommandExecution.run(
            operation: { throw Failure.modelLoad },
            shutdown: { events.append("shutdown") },
            reportError: { _ in events.append("error") }
        )
        #expect(status == 1)
        #expect(events == ["error", "shutdown"])
    }

    @Test func successfulCommandCleansUpAndReportsSuccess() async {
        var events: [String] = []
        let status = await LiveCommandExecution.run(
            operation: { events.append("finished") },
            shutdown: { events.append("shutdown") },
            reportError: { _ in events.append("unexpected error") }
        )
        #expect(status == 0)
        #expect(events == ["finished", "shutdown"])
    }

    @Test func cancellationRemainsASuccessfulShutdown() async {
        var events: [String] = []
        let status = await LiveCommandExecution.run(
            operation: { throw CancellationError() },
            shutdown: { events.append("shutdown") },
            reportError: { _ in events.append("unexpected error") }
        )
        #expect(status == 0)
        #expect(events == ["shutdown"])
    }
}
