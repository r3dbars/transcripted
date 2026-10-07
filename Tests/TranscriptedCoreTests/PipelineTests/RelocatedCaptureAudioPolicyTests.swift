import XCTest
@testable import TranscriptedCore

/// Whether a failed-queue row from a previous capture library is kept while
/// its audio can't be checked, or dropped once the audio is provably gone.
/// Every file-system answer is faked; no real mounts or permissions.
final class RelocatedCaptureAudioPolicyTests: XCTestCase {
    private let mic = URL(fileURLWithPath: "/Volumes/Sweep Drive/old-library/meetings/audio/Call_audio/microphone.wav")
    private let homeMic = URL(fileURLWithPath: "/Users/sweeptester/old-library/meetings/audio/Call_audio/microphone.wav")

    private func fileSystem(
        existingDirectories: Set<String>,
        mountPoints: Set<String> = [],
        deniedDirectories: Set<String> = []
    ) -> RelocatedCaptureAudioPolicy.FileSystem {
        RelocatedCaptureAudioPolicy.FileSystem(
            fileExists: { existingDirectories.contains($0) },
            directoryExists: { existingDirectories.contains($0) },
            isMountPoint: { mountPoints.contains($0) },
            isAccessDenied: { deniedDirectories.contains($0) }
        )
    }

    func testKeepsRowWhenItsVolumeIsNotMounted() {
        let fs = fileSystem(existingDirectories: ["/", "/Volumes"])
        XCTAssertTrue(RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: mic, systemAudioURL: nil, fileSystem: fs))
    }

    func testKeepsRowWhenTheVolumeFolderIsAStaleEmptyDirectoryNotAMount() {
        let fs = fileSystem(existingDirectories: ["/", "/Volumes", "/Volumes/Sweep Drive"])
        XCTAssertTrue(
            RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: mic, systemAudioURL: nil, fileSystem: fs),
            "a leftover /Volumes folder that isn't mounted still means the drive is offline"
        )
    }

    func testDropsRowWhenTheLibraryWasDeletedFromAMountedVolume() {
        let fs = fileSystem(
            existingDirectories: ["/", "/Volumes", "/Volumes/Sweep Drive"],
            mountPoints: ["/Volumes/Sweep Drive"]
        )
        XCTAssertFalse(
            RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: mic, systemAudioURL: nil, fileSystem: fs),
            "the drive is mounted and the library is gone from it, so the audio is provably gone"
        )
    }

    func testDropsRowWhenTheLibraryWasDeletedFromTheStartupDisk() {
        let fs = fileSystem(existingDirectories: ["/", "/Users", "/Users/sweeptester"], mountPoints: ["/"])
        XCTAssertFalse(RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: homeMic, systemAudioURL: nil, fileSystem: fs))
    }

    func testKeepsRowWhenTheNearestFolderRefusesAccess() {
        let fs = fileSystem(
            existingDirectories: ["/", "/Users", "/Users/sweeptester"],
            mountPoints: ["/"],
            deniedDirectories: ["/Users/sweeptester"]
        )
        XCTAssertTrue(
            RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: homeMic, systemAudioURL: nil, fileSystem: fs),
            "a folder we aren't allowed to read can't prove the audio is gone"
        )
    }
}
