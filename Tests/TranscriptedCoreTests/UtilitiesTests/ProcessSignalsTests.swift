import Darwin
import Foundation
import XCTest
@testable import TranscriptedCore

final class ProcessSignalsTests: XCTestCase {
    func testIgnoreSIGPIPELeavesDispositionIgnored() {
        _ = signal(SIGPIPE, SIG_DFL)
        ProcessSignals.ignoreSIGPIPE()
        let previous = signal(SIGPIPE, SIG_DFL)
        ProcessSignals.ignoreSIGPIPE()
        XCTAssertTrue(isIgnore(previous), "ignoreSIGPIPE should set SIGPIPE to SIG_IGN")
    }

    func testWriteToClosedPipeReturnsEPIPE() throws {
        ProcessSignals.ignoreSIGPIPE()

        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0, "pipe() should create a pair")
        close(fds[0])
        var byte: UInt8 = 0x41
        let written = write(fds[1], &byte, 1)
        let posixError = errno
        close(fds[1])
        XCTAssertEqual(written, -1, "write on a closed read end should fail")
        XCTAssertEqual(posixError, EPIPE, "the failure should be EPIPE, not a SIGPIPE kill")

        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try pipe.fileHandleForWriting.write(contentsOf: Data([0x41, 0x0A]))) { error in
            XCTAssertTrue(isEPIPE(error),
                          "FileHandle.write should throw EPIPE the same way Next Sentence's stdin write does, got \(error)")
        }
    }

    private func isIgnore(_ handler: sig_t?) -> Bool {
        guard let handler else { return false }
        return unsafeBitCast(handler, to: UnsafeRawPointer.self)
            == unsafeBitCast(SIG_IGN, to: UnsafeRawPointer.self)
    }

    private func isEPIPE(_ error: Error) -> Bool {
        if let posix = error as? POSIXError { return posix.code == .EPIPE }
        let nsError = error as NSError
        if nsError.code == Int(EPIPE) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.code == Int(EPIPE)
        }
        return false
    }
}
