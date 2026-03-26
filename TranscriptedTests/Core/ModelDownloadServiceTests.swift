import XCTest
@testable import Transcripted

final class ModelDownloadServiceTests: XCTestCase {

    // MARK: - DownloadErrorKind Properties

    func testEveryErrorKindHasNonEmptyTitle() {
        let kinds: [DownloadErrorKind] = [
            .networkOffline,
            .tlsFailure,
            .timeout,
            .diskSpace,
            .serverError(statusCode: 500),
            .unknown("test")
        ]
        for kind in kinds {
            XCTAssertFalse(kind.title.isEmpty, "\(kind) has empty title")
        }
    }

    func testEveryErrorKindHasNonEmptyDetail() {
        let kinds: [DownloadErrorKind] = [
            .networkOffline,
            .tlsFailure,
            .timeout,
            .diskSpace,
            .serverError(statusCode: 500),
            .unknown("test")
        ]
        for kind in kinds {
            XCTAssertFalse(kind.detail.isEmpty, "\(kind) has empty detail")
        }
    }

    func testServerErrorIncludesStatusCodeInDetail() {
        let kind = DownloadErrorKind.serverError(statusCode: 503)
        XCTAssertTrue(kind.detail.contains("503"))
    }

    func testUnknownErrorIncludesMessageInDetail() {
        let kind = DownloadErrorKind.unknown("Custom failure reason")
        XCTAssertEqual(kind.detail, "Custom failure reason")
    }

    // MARK: - Error Classification

    func testClassifyNotConnectedToInternet() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .networkOffline)
    }

    func testClassifyNetworkConnectionLost() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .networkOffline)
    }

    func testClassifyCannotFindHost() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .networkOffline)
    }

    func testClassifyCannotConnectToHost() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .networkOffline)
    }

    func testClassifyDNSLookupFailed() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .networkOffline)
    }

    func testClassifySecureConnectionFailed() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .tlsFailure)
    }

    func testClassifyCertificateUntrusted() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .tlsFailure)
    }

    func testClassifyCertificateBadDate() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateHasBadDate)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .tlsFailure)
    }

    func testClassifyTimedOut() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .timeout)
    }

    func testClassifyDiskSpaceCocoaError() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .diskSpace)
    }

    func testClassifyDiskSpacePOSIXError() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 28) // ENOSPC
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .diskSpace)
    }

    func testClassifyUnknownURLError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown)
        let kind = ModelDownloadService.classifyError(error)
        if case .unknown = kind {} else {
            XCTFail("Expected .unknown for unrecognized URL error, got \(kind)")
        }
    }

    func testClassifyArbitraryError() {
        let error = NSError(domain: "com.test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Random failure"])
        let kind = ModelDownloadService.classifyError(error)
        if case .unknown(let msg) = kind {
            XCTAssertEqual(msg, "Random failure")
        } else {
            XCTFail("Expected .unknown, got \(kind)")
        }
    }

    // MARK: - DownloadErrorKind Equatable

    func testErrorKindEquality() {
        XCTAssertEqual(DownloadErrorKind.networkOffline, .networkOffline)
        XCTAssertEqual(DownloadErrorKind.tlsFailure, .tlsFailure)
        XCTAssertEqual(DownloadErrorKind.timeout, .timeout)
        XCTAssertEqual(DownloadErrorKind.diskSpace, .diskSpace)
        XCTAssertEqual(DownloadErrorKind.serverError(statusCode: 500), .serverError(statusCode: 500))
        XCTAssertNotEqual(DownloadErrorKind.serverError(statusCode: 500), .serverError(statusCode: 503))
        XCTAssertNotEqual(DownloadErrorKind.networkOffline, .timeout)
    }

    // MARK: - ModelDownloadError

    func testModelDownloadErrorDescriptionMatchesKindDetail() {
        let err = ModelDownloadError(kind: .diskSpace, underlyingError: nil)
        XCTAssertEqual(err.errorDescription, DownloadErrorKind.diskSpace.detail)
    }

    // MARK: - Disk Space Check

    func testAvailableDiskSpaceReturnsValue() {
        // Should return a non-nil value on any macOS machine with a valid home directory
        let space = ModelDownloadService.availableDiskSpace()
        XCTAssertNotNil(space)
        if let space = space {
            XCTAssertGreaterThan(space, 0)
        }
    }

    // MARK: - Disk Space Priority

    func testDiskSpaceCheckedBeforeURLErrors() {
        // ENOSPC (POSIX 28) should be classified as diskSpace even though
        // it's not in the URL error domain
        let error = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let kind = ModelDownloadService.classifyError(error)
        XCTAssertEqual(kind, .diskSpace, "Disk space should take priority")
    }
}
