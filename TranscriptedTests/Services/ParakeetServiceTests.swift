import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
@MainActor
final class ParakeetServiceTests: XCTestCase {

    // MARK: - Initial State

    func testFreshServiceStartsInNotLoadedState() {
        let service = ParakeetService()
        XCTAssertEqual(service.modelState, .notLoaded)
        XCTAssertFalse(service.isReady)
    }

    // MARK: - Cleanup resets state

    func testCleanupResetsFromFailedToNotLoaded() async {
        let service = ParakeetService()
        service.modelState = .failed("simulated failure")

        await service.cleanup()

        XCTAssertEqual(service.modelState, .notLoaded)
        XCTAssertFalse(service.isReady)
    }

    // MARK: - Transcribe throws when model not loaded

    func testTranscribeThrowsModelNotLoaded() async {
        let service = ParakeetService()
        let dummyURL = URL(fileURLWithPath: "/tmp/nonexistent.wav")

        do {
            _ = try await service.transcribe(audioURL: dummyURL)
            XCTFail("Expected PipelineError.modelNotLoaded to be thrown")
        } catch let error as PipelineError {
            if case .modelNotLoaded(let model) = error {
                XCTAssertEqual(model, "Parakeet")
            } else {
                XCTFail("Expected .modelNotLoaded, got \(error)")
            }
        } catch {
            XCTFail("Expected PipelineError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - TranscribeSegment throws when model not loaded

    func testTranscribeSegmentThrowsModelNotLoaded() async {
        let service = ParakeetService()
        let dummySamples: [Float] = [0.0, 0.1, -0.1]

        do {
            _ = try await service.transcribeSegment(samples: dummySamples)
            XCTFail("Expected PipelineError.modelNotLoaded to be thrown")
        } catch let error as PipelineError {
            if case .modelNotLoaded(let model) = error {
                XCTAssertEqual(model, "Parakeet")
            } else {
                XCTFail("Expected .modelNotLoaded, got \(error)")
            }
        } catch {
            XCTFail("Expected PipelineError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Model state equality

    func testModelStateEquality() {
        XCTAssertEqual(ParakeetModelState.notLoaded, ParakeetModelState.notLoaded)
        XCTAssertEqual(ParakeetModelState.loading, ParakeetModelState.loading)
        XCTAssertEqual(ParakeetModelState.ready, ParakeetModelState.ready)
        XCTAssertEqual(ParakeetModelState.failed("x"), ParakeetModelState.failed("x"))
        XCTAssertNotEqual(ParakeetModelState.failed("x"), ParakeetModelState.failed("y"))
        XCTAssertNotEqual(ParakeetModelState.notLoaded, ParakeetModelState.loading)
    }
}
