import XCTest
@testable import transcripted_qa

final class NativeSmokeIsolationTests: XCTestCase {
    func testActiveUserCannotBeBypassedByHomeOrCIEnvironment() {
        XCTAssertFalse(allowed(uid: 501, consoleUID: 501))
        XCTAssertFalse(allowed(uid: 501, consoleUID: 501, ci: true, githubActions: true, githubHosted: true))
    }

    func testSeparateNonRootAccountCanRun() {
        XCTAssertTrue(allowed(uid: 502, consoleUID: 501))
    }

    func testUnknownConsoleRootAndImpersonationFailClosed() {
        XCTAssertFalse(allowed(uid: 501, consoleUID: nil))
        XCTAssertFalse(allowed(uid: 501, consoleUID: 0))
        XCTAssertFalse(allowed(uid: 0, consoleUID: 501))
        XCTAssertFalse(allowed(uid: 501, euid: 0, consoleUID: 502))
    }

    func testHostedCIRequiresRunnerAccountOrVM() {
        XCTAssertTrue(allowed(uid: 501, consoleUID: 501, ci: true, githubActions: true, githubHosted: true, virtualMachine: true))
        XCTAssertTrue(allowed(uid: 501, consoleUID: 501, ci: true, githubActions: true, githubHosted: true, hostedRunnerAccount: true))
        XCTAssertFalse(allowed(uid: 501, consoleUID: 501, ci: true, githubActions: true, githubHosted: false, virtualMachine: true))
        XCTAssertFalse(allowed(uid: 501, consoleUID: 501, ci: true, githubActions: true, githubHosted: true, virtualMachine: false))
    }

    private func allowed(
        uid: uid_t,
        euid: uid_t? = nil,
        consoleUID: uid_t?,
        ci: Bool = false,
        githubActions: Bool = false,
        githubHosted: Bool = false,
        virtualMachine: Bool = false,
        hostedRunnerAccount: Bool = false
    ) -> Bool {
        NativeSmokeIsolation.allowed(
            uid: uid,
            euid: euid ?? uid,
            consoleUID: consoleUID,
            ci: ci,
            githubActions: githubActions,
            githubHosted: githubHosted,
            virtualMachine: virtualMachine,
            hostedRunnerAccount: hostedRunnerAccount
        )
    }
}
