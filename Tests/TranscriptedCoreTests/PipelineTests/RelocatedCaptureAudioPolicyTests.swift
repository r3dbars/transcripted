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

    func testKeepsRowWhenTheAudioFolderItselfRefusesAccess() {
        let audioFolder = "/Users/sweeptester/old-library/meetings/audio"
        let fs = fileSystem(
            existingDirectories: ["/", "/Users", "/Users/sweeptester", "/Users/sweeptester/old-library",
                                  "/Users/sweeptester/old-library/meetings", audioFolder],
            mountPoints: ["/"],
            deniedDirectories: [audioFolder]
        )
        XCTAssertTrue(
            RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: homeMic, systemAudioURL: nil, fileSystem: fs),
            "an audio folder we can't read can't prove the audio is gone"
        )
    }
    func testKeepsRowWhenArchiveDirectoryRefusesAccessButItsParentIsReadable() {
        let parent = "/Users/sweeptester/old-library/meetings/audio"
        let archive = parent + "/Call_audio"
        let fs = fileSystem(
            existingDirectories: ["/", parent, archive],
            deniedDirectories: [archive]
        )
        XCTAssertTrue(
            RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: homeMic, systemAudioURL: nil, fileSystem: fs),
            "a readable parent cannot prove audio is gone from an inaccessible archive"
        )
    }

    func testOneOfflineVolumeIsProbedOnceForManyRows() {
        // Several failed meetings from one previous library on a drive that
        // isn't mounted. Asking the policy about each row must not repeat
        // fileExists / directoryExists / statfs / opendir on that share —
        // a hung SMB/NFS mount would multiply one launch stall by the queue.
        var fileExistsCalls: [String] = []
        var directoryExistsCalls: [String] = []
        var mountPointCalls: [String] = []
        var accessDeniedCalls: [String] = []
        let fs = RelocatedCaptureAudioPolicy.FileSystem(
            fileExists: { path in
                fileExistsCalls.append(path)
                return false
            },
            directoryExists: { path in
                directoryExistsCalls.append(path)
                return path == "/" || path == "/Volumes"
            },
            isMountPoint: { path in
                mountPointCalls.append(path)
                return false
            },
            isAccessDenied: { path in
                accessDeniedCalls.append(path)
                return false
            }
        )

        let mics = (1...4).map { index in
            URL(fileURLWithPath: "/Volumes/Sweep Drive/old-library/meetings/audio/Call\(index)_audio/microphone.wav")
        }
        for mic in mics {
            XCTAssertTrue(
                RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: mic, systemAudioURL: nil, fileSystem: fs),
                "an offline volume must keep every relocated row"
            )
        }

        XCTAssertEqual(
            fileExistsCalls.count,
            1,
            "one offline volume must not be file-probed once per relocated row"
        )
        XCTAssertEqual(
            directoryExistsCalls.filter { $0.hasPrefix("/Volumes/Sweep Drive") }.count,
            2,
            "the first row may look at the archive folder and the volume; later rows must not"
        )
        XCTAssertTrue(mountPointCalls.isEmpty, "an absent volume folder never needs statfs")
        XCTAssertTrue(accessDeniedCalls.isEmpty, "an absent volume folder never needs opendir")
    }

}
