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

    func testCheckableLibraryStillProbesEachMissingFile() {
        // The drive is mounted and the old library is gone. Each row still
        // has its own mic path, so fileExists stays per-row; only the
        // volume/statfs/opendir walk is reused after the first miss.
        var fileExistsCalls = 0
        var mountPointCalls = 0
        let fs = RelocatedCaptureAudioPolicy.FileSystem(
            fileExists: { _ in
                fileExistsCalls += 1
                return false
            },
            directoryExists: { ["/", "/Volumes", "/Volumes/Sweep Drive"].contains($0) },
            isMountPoint: { path in
                mountPointCalls += 1
                return path == "/Volumes/Sweep Drive"
            },
            isAccessDenied: { _ in false }
        )
        let mics = (1...3).map { index in
            URL(fileURLWithPath: "/Volumes/Sweep Drive/old-library/meetings/audio/Call\(index)_audio/microphone.wav")
        }
        for mic in mics {
            XCTAssertFalse(
                RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: mic, systemAudioURL: nil, fileSystem: fs),
                "a mounted volume with a missing library can prove each file is gone"
            )
        }
        XCTAssertEqual(fileExistsCalls, 3, "a checkable library still has to look at each mic file")
        XCTAssertEqual(mountPointCalls, 1, "statfs on a mounted volume happens once, not once per row")
    }

    func testEachOfflineVolumeIsProbedOnce() {
        var fileExistsCalls: [String] = []
        let fs = RelocatedCaptureAudioPolicy.FileSystem(
            fileExists: { path in
                fileExistsCalls.append(path)
                return false
            },
            directoryExists: { $0 == "/" || $0 == "/Volumes" },
            isMountPoint: { _ in false },
            isAccessDenied: { _ in false }
        )
        let first = URL(fileURLWithPath: "/Volumes/Sweep Drive/old-library/meetings/audio/Call_audio/microphone.wav")
        let second = URL(fileURLWithPath: "/Volumes/Other Drive/old-library/meetings/audio/Call_audio/microphone.wav")
        XCTAssertTrue(RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: first, systemAudioURL: nil, fileSystem: fs))
        XCTAssertTrue(RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: first, systemAudioURL: nil, fileSystem: fs))
        XCTAssertTrue(RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: second, systemAudioURL: nil, fileSystem: fs))
        XCTAssertEqual(
            fileExistsCalls,
            [first.path, second.path],
            "a second offline volume still needs its own first probe"
        )
    }

    func testCheckableSiblingDoesNotSkipADeniedArchive() {
        // Two meetings in one library: the first archive is gone from a
        // readable disk, the second archive exists but refuses access.
        // Caching "the library is checkable" from the first row must not
        // drop the second — that row is still recoverable.
        let parent = "/Users/sweeptester/old-library/meetings/audio"
        let goneMic = URL(fileURLWithPath: parent + "/Gone_audio/microphone.wav")
        let lockedMic = URL(fileURLWithPath: parent + "/Locked_audio/microphone.wav")
        let lockedArchive = parent + "/Locked_audio"
        let fs = RelocatedCaptureAudioPolicy.FileSystem(
            fileExists: { _ in false },
            directoryExists: {
                [
                    "/",
                    "/Users",
                    "/Users/sweeptester",
                    "/Users/sweeptester/old-library",
                    parent,
                    lockedArchive
                ].contains($0)
            },
            isMountPoint: { $0 == "/" },
            isAccessDenied: { $0 == lockedArchive }
        )
        XCTAssertFalse(
            RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: goneMic, systemAudioURL: nil, fileSystem: fs),
            "a missing archive on a readable disk is dropped"
        )
        XCTAssertTrue(
            RelocatedCaptureAudioPolicy.shouldKeep(micAudioURL: lockedMic, systemAudioURL: nil, fileSystem: fs),
            "a later access-denied sibling archive must still be kept"
        )
    }

}
