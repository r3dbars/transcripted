// StorageRetentionSweepTests.swift
// The meeting and dictation audio sweeps each use only their own window and
// touch only their own folder. A user report on 1.1.75 worried that a 30-day
// meeting choice could delete meeting audio between 7 and 30 days old; these
// pin that it can't. Everything runs in a temp capture library with a fixed
// clock; nothing touches the real library.

import Foundation

func testStorageRetentionSweep() {
    let fm = FileManager.default
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let ages = [5, 20, 40]

    struct Library {
        let root: URL
        let meetingsFolder: URL
        let dictationsFolder: URL
        /// Age in days → that meeting's transcript and its audio directory.
        var meetings: [Int: (transcript: URL, audio: URL)] = [:]
        /// Age in days → that dictation's kept audio file.
        var dictations: [Int: URL] = [:]
    }

    func makeLibrary(_ label: String) -> Library {
        let root = fm.temporaryDirectory.appendingPathComponent(
            "StorageRetentionSweepTests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        var library = Library(
            root: root,
            meetingsFolder: root.appendingPathComponent("meetings", isDirectory: true),
            dictationsFolder: root.appendingPathComponent("dictations", isDirectory: true)
        )
        for days in ages {
            let transcript = writeMeetingTranscript(
                named: "Planning Sync \(days)d", in: library.meetingsFolder, ageDays: days, now: now
            )
            let audio = library.meetingsFolder
                .appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent("Planning Sync \(days)d_audio", isDirectory: true)
            try? fm.createDirectory(at: audio, withIntermediateDirectories: true)
            try? Data("m4a".utf8).write(to: audio.appendingPathComponent("recording.m4a"))
            library.meetings[days] = (transcript, audio)

            let take = DictationAudioArchive.audioFolder(in: library.dictationsFolder)
                .appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
            try? fm.createDirectory(at: take.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("m4a".utf8).write(to: take)
            let date = now.addingTimeInterval(-Double(days) * 86_400)
            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: take.path)
            library.dictations[days] = take
        }
        return library
    }

    func sweep(_ library: Library, meeting: AudioRetentionWindow, dictation: DictationAudioKeepWindow) {
        MeetingAudioStorageManager.pruneRetainedAudio(
            in: library.meetingsFolder, retentionWindow: meeting, now: now
        )
        DictationAudioArchive.prune(window: dictation, now: now, dictationsFolder: library.dictationsFolder)
    }

    func keptMeetingAges(_ library: Library) -> [Int] {
        ages.filter { fm.fileExists(atPath: library.meetings[$0]!.audio.appendingPathComponent("recording.m4a").path) }
    }

    func keptDictationAges(_ library: Library) -> [Int] {
        ages.filter { fm.fileExists(atPath: library.dictations[$0]!.path) }
    }

    func assertTranscriptsKept(_ library: Library, _ label: String) {
        for days in ages {
            assertTrue(
                fm.fileExists(atPath: library.meetings[days]!.transcript.path),
                "\(label): the \(days)-day meeting transcript is never deleted"
            )
        }
    }

    runSuite("Meeting audio 30 days keeps meeting audio younger than 30 days while dictation uses 7 days") {
        let library = makeLibrary("meeting30-dictation7")
        defer { try? fm.removeItem(at: library.root) }

        sweep(library, meeting: .thirtyDays, dictation: .sevenDays)

        assertEqual(keptMeetingAges(library), [5, 20], "the 20-day meeting audio survives a 30-day meeting window")
        assertEqual(keptDictationAges(library), [5], "dictation follows its own 7-day window")
        assertTranscriptsKept(library, "meeting 30 / dictation 7")
    }

    runSuite("Dictation audio 30 days keeps dictation audio younger than 30 days while meetings use 7 days") {
        let library = makeLibrary("meeting7-dictation30")
        defer { try? fm.removeItem(at: library.root) }

        sweep(library, meeting: .sevenDays, dictation: .thirtyDays)

        assertEqual(keptMeetingAges(library), [5], "meetings follow their own 7-day window")
        assertEqual(keptDictationAges(library), [5, 20], "the 20-day dictation audio survives a 30-day dictation window")
        assertTranscriptsKept(library, "meeting 7 / dictation 30")
    }

    runSuite("Meeting audio set to Never keeps every meeting recording even when dictation keeps none") {
        let library = makeLibrary("meetingNever-dictationOff")
        defer { try? fm.removeItem(at: library.root) }

        sweep(library, meeting: .never, dictation: .off)

        assertEqual(keptMeetingAges(library), ages, "Never deletes no meeting audio")
        assertEqual(keptDictationAges(library), [], "Don't keep removes every kept dictation take")
        assertTranscriptsKept(library, "meeting Never / dictation off")
    }

    runSuite("Each audio sweep leaves the other kind's files alone even if pointed at its folder") {
        let library = makeLibrary("crossed-folders")
        defer { try? fm.removeItem(at: library.root) }

        // The harshest window of each sweep, run over the other one's folder.
        DictationAudioArchive.prune(window: .off, now: now, dictationsFolder: library.meetingsFolder)
        MeetingAudioStorageManager.pruneRetainedAudio(
            in: library.dictationsFolder, retentionWindow: .sevenDays, now: now
        )

        assertEqual(keptMeetingAges(library), ages, "the dictation sweep never deletes meeting audio")
        assertEqual(keptDictationAges(library), ages, "the meeting sweep never deletes dictation audio")
        assertTranscriptsKept(library, "crossed folders")
    }
}

private func writeMeetingTranscript(named name: String, in folder: URL, ageDays: Int, now: Date) -> URL {
    let url = folder.appendingPathComponent(name).appendingPathExtension("md")
    let date = Calendar.current.date(byAdding: .day, value: -ageDays, to: now)!
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let timeFormatter = DateFormatter()
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")
    timeFormatter.dateFormat = "HH:mm:ss"
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? """
    ---
    capture_id: "\(UUID().uuidString)"
    capture_type: meeting
    transcript_id: "\(UUID().uuidString)"
    date: "\(dateFormatter.string(from: date))"
    time: "\(timeFormatter.string(from: date))"
    duration: "1:00"
    total_word_count: "4"
    mic_utterances: "1"
    system_utterances: "0"
    ---

    ## Full Transcript

    **[00:00] [Mic/You]**
    Synthetic planning notes.
    """.write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
}
