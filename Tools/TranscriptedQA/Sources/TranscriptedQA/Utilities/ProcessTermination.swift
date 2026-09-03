import Darwin
import Foundation

func terminateProcess(_ process: Process, gracePeriod: TimeInterval = 2, pollInterval: TimeInterval = 0.1) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(gracePeriod)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: pollInterval)
    }
    if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
