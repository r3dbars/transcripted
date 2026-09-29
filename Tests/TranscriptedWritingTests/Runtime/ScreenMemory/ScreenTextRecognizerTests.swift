import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// Vision can report the same failure twice (completion handler and a throw
/// from `perform`). A second answer must be ignored, not crash the app.
@Suite("Screen text recognizer")
struct ScreenTextRecognizerTests {
    private struct VisionFailed: Error, Equatable {}

    @Test("the first answer wins and a second one is ignored")
    func secondResumeIsIgnored() async {
        let result: Result<Int, Error> = await Result {
            try await withCheckedThrowingContinuation { checked in
                let once = ScreenTextRecognizer.OneShotContinuation<Int>(checked)
                once.resume(throwing: VisionFailed())
                once.resume(throwing: VisionFailed())
                once.resume(returning: 7)
            }
        }
        switch result {
        case .success: Issue.record("the error that arrived first should be what the caller sees")
        case .failure(let error): #expect(error is VisionFailed)
        }
    }

    @Test("a value delivered first is returned even if an error follows")
    func valueThenErrorReturnsValue() async throws {
        let value: Int = try await withCheckedThrowingContinuation { checked in
            let once = ScreenTextRecognizer.OneShotContinuation<Int>(checked)
            once.resume(returning: 3)
            once.resume(throwing: VisionFailed())
        }
        #expect(value == 3)
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
