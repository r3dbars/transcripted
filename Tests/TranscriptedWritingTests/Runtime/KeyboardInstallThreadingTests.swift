import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

/// Records which thread each install step ran on and which steps ran. No
/// step touches the disk or the real Input Sources.
private final class InstallStepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var prepareOnMain: Bool?
    private var inputSourcesCallsOffMain = 0

    func notePrepare() {
        let onMain = Thread.isMainThread
        lock.withLock {
            prepareOnMain = onMain
            events.append("prepare")
        }
    }

    func noteInputSources(_ event: String) {
        let onMain = Thread.isMainThread
        lock.withLock {
            if !onMain { inputSourcesCallsOffMain += 1 }
            events.append(event)
        }
    }

    var preparedOnMain: Bool? { lock.withLock { prepareOnMain } }
    var offMainInputSourcesCalls: Int { lock.withLock { inputSourcesCallsOffMain } }
    var steps: [String] { lock.withLock { events } }
}

@MainActor
private func steps(
    preparation: GhostKeyboardInstallerHost.InstallPreparation,
    alreadyRegistered: Bool = true,
    registerSucceeds: Bool = true,
    recorder: InstallStepRecorder
) -> GhostKeyboardInstallerHost.InstallSteps {
    GhostKeyboardInstallerHost.InstallSteps(
        prepare: {
            recorder.notePrepare()
            return preparation
        },
        isRegistered: {
            recorder.noteInputSources("isRegistered")
            return alreadyRegistered
        },
        register: {
            recorder.noteInputSources("register")
            return registerSucceeds
        },
        restartRunningKeyboard: {
            recorder.noteInputSources("restart")
        }
    )
}

@Suite("Keyboard install threading")
@MainActor
struct KeyboardInstallThreadingTests {
    @Test("The file and signature work runs off the main thread, even when the caller is on it")
    func prepareRunsOffMain() async {
        let recorder = InstallStepRecorder()
        let result = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .ready(changed: true), recorder: recorder)
        )
        #expect(result == .installed)
        #expect(recorder.preparedOnMain == false)
    }

    @Test("Text Input Sources calls stay on the main thread")
    func inputSourcesCallsStayOnMain() async {
        let recorder = InstallStepRecorder()
        _ = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .ready(changed: true), recorder: recorder)
        )
        _ = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .ready(changed: false), alreadyRegistered: false, recorder: recorder)
        )
        #expect(recorder.offMainInputSourcesCalls == 0)
        #expect(recorder.steps.contains("register"))
    }

    @Test("An unchanged keyboard Input Sources already lists is not registered again")
    func unchangedListedKeyboardSkipsRegister() async {
        let recorder = InstallStepRecorder()
        let result = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .ready(changed: false), alreadyRegistered: true, recorder: recorder)
        )
        #expect(result == .alreadyInstalled)
        #expect(recorder.steps == ["prepare", "isRegistered"])
    }

    @Test("An unchanged keyboard Input Sources lost is registered again")
    func unchangedUnlistedKeyboardRegisters() async {
        let recorder = InstallStepRecorder()
        let result = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .ready(changed: false), alreadyRegistered: false, recorder: recorder)
        )
        #expect(result == .alreadyInstalled)
        #expect(recorder.steps == ["prepare", "isRegistered", "register"])
    }

    @Test("A fresh copy restarts the running keyboard, then registers")
    func changedKeyboardRestartsThenRegisters() async {
        let recorder = InstallStepRecorder()
        let result = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .ready(changed: true), recorder: recorder)
        )
        #expect(result == .installed)
        #expect(recorder.steps == ["prepare", "restart", "register"])
    }

    @Test("A failed register is a failed install")
    func failedRegisterFails() async {
        let recorder = InstallStepRecorder()
        let result = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .ready(changed: true), registerSucceeds: false, recorder: recorder)
        )
        #expect(result == .failed)
    }

    @Test("A failed or unavailable preparation makes no Input Sources call")
    func failedPreparationSkipsInputSources() async {
        let failed = InstallStepRecorder()
        let failedResult = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .failed, recorder: failed)
        )
        let missing = InstallStepRecorder()
        let missingResult = await GhostKeyboardInstallerHost.installOrUpdate(
            using: steps(preparation: .unavailableInDevelopment, recorder: missing)
        )
        #expect(failedResult == .failed)
        #expect(failed.steps == ["prepare"])
        #expect(missingResult == .unavailableInDevelopment)
        #expect(missing.steps == ["prepare"])
    }
}
