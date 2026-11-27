import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Plays a meeting's kept audio on the Meetings page: play, pause, resume,
/// seek, skip, a transcript line's time, and a real playback speed (1×,
/// 1.25×, 1.5×, 2×). Built on `AVAudioPlayer` with `enableRate`, so a faster
/// speed keeps the pitch. A choice with more than one file (older meetings
/// that kept Mic and System but no Mix) plays them together, started on one
/// shared device time so they stay in step.
///
/// Files open off the main actor (an evicted or slow file must never freeze
/// the window); the request that was asked for last wins. Output only: no
/// audio engine, no input node, so a Bluetooth headset as the default input
/// is never touched here.
@MainActor
final class MeetingAudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = MeetingAudioPlayback()

    /// The speeds the player offers, in the order its speed button steps.
    nonisolated static let playbackRates: [Float] = [1, 1.25, 1.5, 2]

    @Published private(set) var activeAttachmentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isLoading = false
    @Published private(set) var unavailablePlaybackID: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var activeChoiceID: String?
    /// The speed every meeting plays at, kept across meetings while the app runs.
    @Published private(set) var playbackRate: Float = 1
    /// Real file durations probed off the main actor for meetings whose
    /// frontmatter didn't record an end time.
    @Published private(set) var probedDurations: [String: TimeInterval] = [:]
    /// Source stem ("microphone", "system_audio", ...) picked in the player,
    /// so a transcript timestamp click starts the same source the menu shows.
    /// Keyed by the meeting's audio folder, not the file paths, so a pick
    /// survives the Home rescan after WAV→M4A recompression.
    @Published private var pickedSourceStems: [String: String] = [:]

    private var players: [AVAudioPlayer] = []
    private var progressTimer: Timer?
    /// Bumped by every new start and by stop, so a file that finishes
    /// opening after the person asked for something else is dropped.
    private var loadGeneration = 0
    /// The meeting whose files are opening right now, if any.
    private var loadingAttachmentID: String?
    /// Latest requested playhead and pause state while an async file open is in
    /// flight, so scrubbing or pausing mid-load never snaps back.
    private var pendingStartTime: TimeInterval = 0
    private var pendingStartPaused = false
    /// Avoids reading stale or pre-roll AVAudioPlayer.currentTime during the
    /// 30ms multi-track synchronized start window right after a seek.
    private var seekSettleDeadline: TimeInterval = 0
    private var probingAttachmentIDs: Set<String> = []

    func toggle(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) {
        let choiceID = (choice ?? preferredChoice(for: attachment))?.id
        let matchesChoice = choice == nil || activeChoiceID == nil || activeChoiceID == choiceID
        if activeAttachmentID == attachment.id && matchesChoice {
            if isPlaying {
                pause()
            } else if isPaused {
                resume()
            } else {
                play(attachment, choice: choice ?? preferredChoice(for: attachment))
            }
            return
        }

        play(attachment, choice: choice ?? preferredChoice(for: attachment))
    }

    func play(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) {
        play(attachment, choice: choice, startTime: 0, startPaused: false)
    }

    func switchSource(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice) {
        guard isActive(attachment) else {
            play(attachment, choice: choice)
            return
        }

        play(
            attachment,
            choice: choice,
            startTime: currentPlaybackTime(for: attachment),
            startPaused: isPaused
        )
    }

    /// Best known length for a meeting's audio, falling back from active player
    /// duration -> probed file duration -> frontmatter span -> nil.
    func knownDuration(for attachment: MeetingAudioAttachment, fallback: TimeInterval?) -> TimeInterval {
        if isActive(attachment), duration > 0 { return duration }
        if let probed = probedDurations[attachment.id], probed > 0 { return probed }
        if let fallback, fallback > 0 { return fallback }
        return 0
    }

    /// Reads the file's real length once off the main actor so meetings without
    /// a saved end timestamp still show their playhead, clock and hover pill.
    func probeDurationIfNeeded(for attachment: MeetingAudioAttachment) {
        if isActive(attachment), duration > 0 { return }
        if let probed = probedDurations[attachment.id], probed > 0 { return }
        guard probingAttachmentIDs.insert(attachment.id).inserted else { return }
        let choice = preferredChoice(for: attachment) ?? attachment.defaultPlaybackChoice
        let urls = choice?.urls ?? []
        guard !urls.isEmpty else {
            probingAttachmentIDs.remove(attachment.id)
            return
        }
        let attachmentID = attachment.id
        Task { @MainActor [weak self] in
            let measured = await Self.measureDuration(for: urls)
            guard let self else { return }
            self.probingAttachmentIDs.remove(attachmentID)
            if let measured, measured > 0 {
                self.probedDurations[attachmentID] = measured
                if self.activeAttachmentID == attachmentID, self.duration <= 0 {
                    self.duration = measured
                }
            }
        }
    }

    private func play(
        _ attachment: MeetingAudioAttachment,
        choice: MeetingAudioPlaybackChoice?,
        startTime: TimeInterval,
        startPaused: Bool,
        rejectsStartPastEnd: Bool = false
    ) {
        let requestedChoice = choice ?? preferredChoice(for: attachment) ?? attachment.defaultPlaybackChoice
        let candidates = MeetingAudioPlaybackLoadingPolicy.choices(for: attachment, preferredChoice: requestedChoice)
        loadGeneration &+= 1
        let generation = loadGeneration

        // Update state optimistically on the main actor so Play/Pause and the
        // playhead reflect the user's click immediately with zero snap-back.
        stopProgressTimer()
        releasePlayers()
        loadingAttachmentID = attachment.id
        isLoading = true
        unavailablePlaybackID = nil
        activeAttachmentID = attachment.id
        activeChoiceID = requestedChoice?.id
        let clampedStart = max(startTime, 0)
        pendingStartTime = clampedStart
        pendingStartPaused = startPaused
        let known = probedDurations[attachment.id] ?? 0
        duration = known > 0 ? known : max(duration, clampedStart)
        currentTime = known > 0 ? min(clampedStart, known) : clampedStart
        isPlaying = !startPaused
        isPaused = startPaused

        Task { @MainActor [weak self] in
            let loaded = await Self.openPlayers(for: candidates.map(\.urls))
            guard let self, generation == self.loadGeneration else { return }
            self.loadingAttachmentID = nil
            self.isLoading = false
            guard let loaded, candidates.indices.contains(loaded.index) else {
                self.stop()
                self.unavailablePlaybackID = self.playbackID(for: attachment, choice: requestedChoice)
                NSSound.beep()
                return
            }
            self.start(
                loaded.box.players,
                attachment: attachment,
                choice: candidates[loaded.index],
                startTime: self.pendingStartTime,
                startPaused: self.pendingStartPaused,
                rejectsStartPastEnd: rejectsStartPastEnd
            )
        }
    }

    private func start(
        _ loadedPlayers: [AVAudioPlayer],
        attachment: MeetingAudioAttachment,
        choice: MeetingAudioPlaybackChoice,
        startTime: TimeInterval,
        startPaused: Bool,
        rejectsStartPastEnd: Bool
    ) {
        let loadedDuration = loadedPlayers.map(\.duration).max() ?? 0
        if loadedDuration > 0 {
            probedDurations[attachment.id] = loadedDuration
        }
        // A transcript time can sit past the end of a shorter source (Mic vs
        // System). Starting there would finish instantly and reset the player,
        // so leave whatever is playing alone and just beep.
        if rejectsStartPastEnd, startTime > 0, startTime >= loadedDuration {
            stop()
            NSSound.beep()
            return
        }

        releasePlayers()

        unavailablePlaybackID = nil
        activeAttachmentID = attachment.id
        activeChoiceID = choice.id
        players = loadedPlayers
        duration = loadedDuration
        currentTime = min(max(startTime, 0), loadedDuration)
        isPlaying = !startPaused
        isPaused = startPaused

        for player in players {
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            player.currentTime = min(currentTime, max(player.duration, 0))
        }

        if startPaused {
            stopProgressTimer()
        } else {
            let started = startPlayersTogether()
            isPlaying = started
            isPaused = !started
            if started {
                startProgressTimer()
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        if isLoading {
            pendingStartPaused = true
            isPlaying = false
            isPaused = true
            return
        }
        currentTime = livePlayerTime() ?? currentTime
        for player in players {
            player.pause()
        }
        stopProgressTimer()
        isPlaying = false
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        if isLoading {
            pendingStartPaused = false
            isPlaying = true
            isPaused = false
            return
        }
        guard !players.isEmpty else { return }
        // A track that already ran out stays quiet; the others pick up where
        // the playhead is.
        let resumed = startPlayersTogether()
        isPlaying = resumed
        isPaused = !resumed
        if resumed {
            startProgressTimer()
        }
    }

    func stop() {
        loadGeneration &+= 1
        loadingAttachmentID = nil
        isLoading = false
        pendingStartTime = 0
        pendingStartPaused = false
        seekSettleDeadline = 0
        stopProgressTimer()
        releasePlayers()
        activeAttachmentID = nil
        activeChoiceID = nil
        isPlaying = false
        isPaused = false
        unavailablePlaybackID = nil
        currentTime = 0
        duration = 0
    }

    func stopIfActive(attachmentIDs: Set<String>) {
        if let loadingAttachmentID, attachmentIDs.contains(loadingAttachmentID) {
            stop()
            return
        }
        guard let activeAttachmentID, attachmentIDs.contains(activeAttachmentID) else {
            return
        }
        stop()
    }

    func isActive(_ attachment: MeetingAudioAttachment) -> Bool {
        activeAttachmentID == attachment.id
    }

    func isActive(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice?) -> Bool {
        guard activeAttachmentID == attachment.id else { return false }
        guard let choice else { return true }
        return activeChoiceID == choice.id
    }

    /// The source the player menu shows for an idle meeting.
    func preferredChoice(for attachment: MeetingAudioAttachment) -> MeetingAudioPlaybackChoice? {
        pickedChoice(for: attachment) ?? attachment.defaultPlaybackChoice
    }

    func setPreferredChoiceID(_ choiceID: String?, for attachment: MeetingAudioAttachment) {
        pickedSourceStems[Self.pickKey(for: attachment)] = choiceID.map(MeetingAudioPlaybackLoadingPolicy.sourceStem(ofChoiceID:))
    }

    private func pickedChoice(for attachment: MeetingAudioAttachment) -> MeetingAudioPlaybackChoice? {
        guard let stem = pickedSourceStems[Self.pickKey(for: attachment)] else { return nil }
        return MeetingAudioPlaybackLoadingPolicy.choice(in: attachment, sourceStem: stem)
    }

    private static func pickKey(for attachment: MeetingAudioAttachment) -> String {
        attachment.directoryURL.standardizedFileURL.path
    }

    func activeChoice(for attachment: MeetingAudioAttachment) -> MeetingAudioPlaybackChoice? {
        guard activeAttachmentID == attachment.id else { return nil }
        return attachment.playbackChoice(id: activeChoiceID)
    }

    func seek(_ attachment: MeetingAudioAttachment, progress: Double) {
        guard isActive(attachment) else { return }
        let effectiveDuration = knownDuration(for: attachment, fallback: duration)
        guard effectiveDuration > 0 else { return }
        let clampedProgress = min(max(progress, 0), 1)
        let targetTime = effectiveDuration * clampedProgress
        currentTime = targetTime
        if isLoading {
            pendingStartTime = targetTime
            return
        }

        let wasPlaying = isPlaying
        for player in players {
            player.pause()
            player.currentTime = min(targetTime, max(player.duration, 0))
        }
        if wasPlaying {
            startPlayersTogether()
        }
    }

    /// Plays the meeting from `time` seconds in. Used by transcript timestamps:
    /// seeks the loaded audio (keeping the chosen source) and resumes if paused,
    /// or starts this meeting's audio there when something else was loaded.
    /// `rowSourceStem` is the clicked row's own track ("microphone" for a Mic
    /// row). It only decides the source when the user hasn't picked one and
    /// the meeting has no Mix yet, so a "You" row plays your mic, not System.
    func play(
        _ attachment: MeetingAudioAttachment,
        from time: TimeInterval,
        rowSourceStem: String? = nil
    ) {
        if isActive(attachment), isLoading {
            let clamped = max(time, 0)
            pendingStartTime = clamped
            pendingStartPaused = false
            currentTime = clamped
            isPlaying = true
            isPaused = false
            return
        }

        guard isActive(attachment), duration > 0 else {
            play(
                attachment,
                choice: pickedChoice(for: attachment)
                    ?? MeetingAudioPlaybackLoadingPolicy.rowChoice(in: attachment, rowSourceStem: rowSourceStem),
                startTime: time,
                startPaused: false,
                rejectsStartPastEnd: true
            )
            return
        }

        guard time < duration else {
            NSSound.beep()
            return
        }

        seek(attachment, progress: time / duration)
        if isPaused {
            resume()
        }
    }

    func skip(_ attachment: MeetingAudioAttachment, by seconds: TimeInterval) {
        guard isActive(attachment) else { return }
        let effectiveDuration = knownDuration(for: attachment, fallback: duration)
        guard effectiveDuration > 0 else { return }
        let now = isLoading ? pendingStartTime : (livePlayerTime() ?? currentTime)
        let targetTime = min(max(now + seconds, 0), effectiveDuration)
        seek(attachment, progress: targetTime / effectiveDuration)
    }

    func progress(for attachment: MeetingAudioAttachment) -> Double {
        guard isActive(attachment), duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    /// The playhead read straight from the players while this meeting plays,
    /// so a view redrawing every frame (`TimelineView(.animation)`) moves
    /// smoothly between the published quarter-second ticks. 0 when another
    /// meeting (or nothing) is loaded.
    func currentPlaybackTime(for attachment: MeetingAudioAttachment) -> TimeInterval {
        guard isActive(attachment) else { return 0 }
        if isLoading || ProcessInfo.processInfo.systemUptime < seekSettleDeadline {
            return currentTime
        }
        guard isPlaying, let live = livePlayerTime() else { return currentTime }
        return live
    }

    // MARK: Speed

    /// Sets the speed for this and every later meeting, 0.5× to 2×.
    func setPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 2)
        guard clamped != playbackRate else { return }
        playbackRate = clamped
        guard !players.isEmpty else { return }
        if isPlaying, players.count > 1 {
            // Separate tracks drift if each changes speed on its own; line
            // them up on the playhead and start them together again.
            let now = livePlayerTime() ?? currentTime
            for player in players {
                player.pause()
                player.rate = clamped
                player.currentTime = min(now, max(player.duration, 0))
            }
            currentTime = now
            startPlayersTogether()
        } else {
            players.forEach { $0.rate = clamped }
        }
    }

    /// 1× → 1.25× → 1.5× → 2× → 1×.
    func cyclePlaybackRate() {
        setPlaybackRate(Self.nextPlaybackRate(after: playbackRate))
    }

    nonisolated static func nextPlaybackRate(after rate: Float) -> Float {
        guard let index = playbackRates.firstIndex(where: { abs($0 - rate) < 0.01 }) else { return playbackRates[0] }
        return playbackRates[(index + 1) % playbackRates.count]
    }

    func buttonTitle(for attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) -> String {
        if isUnavailable(attachment, choice: choice) { return "Unavailable" }
        guard isActive(attachment, choice: choice) else { return "Play" }
        if isPlaying { return "Pause" }
        if isPaused { return "Resume" }
        return "Play"
    }

    func symbolName(for attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) -> String {
        if isUnavailable(attachment, choice: choice) { return "exclamationmark.triangle.fill" }
        guard isActive(attachment, choice: choice) else { return "play.fill" }
        if isPlaying { return "pause.fill" }
        return "play.fill"
    }

    func isUnavailable(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) -> Bool {
        unavailablePlaybackID == playbackID(for: attachment, choice: choice ?? attachment.defaultPlaybackChoice)
    }

    // MARK: Players

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handlePlayerFinished()
        }
    }

    private func handlePlayerFinished() {
        guard isPlaying else { return }
        guard !players.contains(where: { $0.isPlaying }) else { return }
        stop()
    }

    /// Starts every track that still has audio at the playhead on one shared
    /// device time, so split tracks stay in step. False when none could.
    @discardableResult
    private func startPlayersTogether() -> Bool {
        let playable = players.filter { $0.currentTime < $0.duration }
        guard let anchor = playable.first else { return false }
        if playable.count == 1 {
            seekSettleDeadline = 0
            return anchor.play()
        }
        let startAt = anchor.deviceCurrentTime + 0.03
        seekSettleDeadline = ProcessInfo.processInfo.systemUptime + 0.06
        var started = false
        for player in playable {
            started = player.play(atTime: startAt) || started
        }
        return started
    }

    private func releasePlayers() {
        for player in players {
            player.stop()
            player.delegate = nil
        }
        players.removeAll()
    }

    /// The furthest track's position, or nil with nothing loaded.
    private func livePlayerTime() -> TimeInterval? {
        guard !players.isEmpty, duration > 0 else { return nil }
        if ProcessInfo.processInfo.systemUptime < seekSettleDeadline {
            return currentTime
        }
        let latest = players.map(\.currentTime).max() ?? 0
        return min(max(latest, 0), duration)
    }

    /// Measures audio file length off the main actor using `AVAudioFile`.
    private nonisolated static func measureDuration(for urls: [URL]) async -> TimeInterval? {
        await Task.detached(priority: .utility) { () -> TimeInterval? in
            var maxDuration: TimeInterval = 0
            for url in urls {
                let playable = MeetingAudioPlaybackLoadingPolicy.playableURL(for: url)
                if let file = try? AVAudioFile(forReading: playable), file.processingFormat.sampleRate > 0 {
                    let secs = Double(file.length) / file.processingFormat.sampleRate
                    if secs > maxDuration { maxDuration = secs }
                }
            }
            return maxDuration > 0 ? maxDuration : nil
        }.value
    }

    /// Opens the first candidate whose files all open, off the main actor.
    private nonisolated static func openPlayers(for candidates: [[URL]]) async -> (index: Int, box: LoadedPlayers)? {
        await Task.detached(priority: .userInitiated) { () -> (index: Int, box: LoadedPlayers)? in
            for (index, urls) in candidates.enumerated() where !urls.isEmpty {
                let opened = urls.compactMap { url -> AVAudioPlayer? in
                    let playable = MeetingAudioPlaybackLoadingPolicy.playableURL(for: url)
                    guard let player = try? AVAudioPlayer(contentsOf: playable) else { return nil }
                    player.enableRate = true
                    player.prepareToPlay()
                    return player
                }
                if opened.count == urls.count {
                    return (index, LoadedPlayers(players: opened))
                }
            }
            return nil
        }.value
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePlaybackTime()
            }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updatePlaybackTime()
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updatePlaybackTime() {
        guard let live = livePlayerTime() else {
            currentTime = 0
            return
        }
        currentTime = live
    }

    private func playbackID(for attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice?) -> String {
        "\(attachment.id)#\(choice?.id ?? "default")"
    }

    /// "0:19", "32:10", "1:02:03": the clock the Meetings card bar and its
    /// transcript times show.
    nonisolated static func clockText(_ time: TimeInterval) -> String {
        formatTime(time)
    }

    private nonisolated static func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Players opened off the main actor and handed to it once. Nothing touches
/// them on the way, so moving them across is safe.
private final class LoadedPlayers: @unchecked Sendable {
    let players: [AVAudioPlayer]

    init(players: [AVAudioPlayer]) {
        self.players = players
    }
}

enum MeetingAudioPlaybackLoadingPolicy {
    /// Retained audio can be recompressed (WAV→M4A) or moved after the row was
    /// scanned. Resolve to the on-disk file (stem-rematch) so playback follows
    /// the drift instead of going silently "Unavailable" on a stale path.
    static func playableURL(for url: URL) -> URL {
        OwnFileResolver.resolveExistingFile(candidateURLs: [url]) ?? url
    }

    /// Choice ids are "<file stem>:<path>"; the stem names the source.
    static func sourceStem(ofChoiceID id: String) -> String {
        String(id.prefix { $0 != ":" })
    }

    static func choice(in attachment: MeetingAudioAttachment, sourceStem: String) -> MeetingAudioPlaybackChoice? {
        attachment.playbackChoices.first { Self.sourceStem(ofChoiceID: $0.id) == sourceStem }
    }

    /// Source for a transcript-row click with no user pick: the row's own
    /// track while the meeting only has split Mic/System files, else the
    /// default (the Mix or single recording already holds every speaker).
    static func rowChoice(
        in attachment: MeetingAudioAttachment,
        rowSourceStem: String?
    ) -> MeetingAudioPlaybackChoice? {
        let fallback = attachment.defaultPlaybackChoice
        guard let rowSourceStem,
              let fallback,
              !["playback", "recording"].contains(Self.sourceStem(ofChoiceID: fallback.id)) else {
            return fallback
        }
        return choice(in: attachment, sourceStem: rowSourceStem) ?? fallback
    }

    static func choices(
        for attachment: MeetingAudioAttachment,
        preferredChoice: MeetingAudioPlaybackChoice?
    ) -> [MeetingAudioPlaybackChoice] {
        let choices = attachment.playbackChoices
        guard let preferredChoice else {
            return choices.first.map { [$0] } ?? []
        }
        guard choices.contains(where: { $0.id == preferredChoice.id }) else {
            return choices.first.map { [$0] } ?? []
        }

        // Source-aware controls should not silently switch from System to Mic.
        // If the selected source cannot load, the user can choose another retained source.
        return [preferredChoice]
    }
}

/// Which kept track plays: Mix, You (the mic) or Others (call audio). Only
/// shown when the meeting kept more than one; sits at the end of the card
/// bar's player.
struct MeetingAudioSourceMenu: View {
    let attachment: MeetingAudioAttachment
    @Binding var selectedChoiceID: String?
    var onSelect: (MeetingAudioPlaybackChoice) -> Void = { _ in }

    private var choices: [MeetingAudioPlaybackChoice] {
        attachment.playbackChoices
    }

    private var selectedChoice: MeetingAudioPlaybackChoice? {
        attachment.playbackChoice(id: selectedChoiceID)
    }

    var body: some View {
        if choices.count > 1, let selectedChoice {
            Menu {
                ForEach(choices) { choice in
                    Button {
                        selectedChoiceID = choice.id
                        onSelect(choice)
                    } label: {
                        Label(Self.title(for: choice), systemImage: choice.id == selectedChoice.id ? "checkmark" : choice.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(Self.title(for: selectedChoice))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .padding(.horizontal, 6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Quiet text, but a full-size target: no pill, just room. On the
            // menu itself, since a borderless menu can drop its label's frame.
            .frame(minHeight: LibraryTokens.minimumHitTarget)
            .contentShape(Rectangle())
            .help("Play the mix, just you, or just the others")
            .accessibilityLabel(Text("Audio track: \(Self.title(for: selectedChoice))"))
            .accessibilityIdentifier("transcripted.home.meeting.audio-source")
        }
    }

    /// The mic track is you and call audio is everyone else, so the picker
    /// says that instead of naming devices.
    static func title(for choice: MeetingAudioPlaybackChoice) -> String {
        MeetingAudioSourceTitle.title(
            sourceStem: MeetingAudioPlaybackLoadingPolicy.sourceStem(ofChoiceID: choice.id),
            fallback: choice.title
        )
    }
}

enum MeetingAudioSourceTitle {
    static func title(sourceStem: String, fallback: String) -> String {
        switch sourceStem {
        case "microphone": return "You"
        case "system_audio": return "Others"
        default: return fallback
        }
    }
}
