import AppKit
import Foundation

@available(macOS 14.0, *)
extension MeetingPromptDetector {
    // Members here that drop `private` do so only because another
    // MeetingPromptDetector file uses them; treat them as private to the type.

    // MARK: - Browser call evidence

    /// What the window titles said during one browser session (a browser mic
    /// session, or a camera-only browser call).
    struct BrowserTitleSession {
        var families: Set<String>
        let startedAt: Date
        /// The latest read's verdict; `nil` until the first read lands.
        var latest: BrowserCallTitleVerdict?
        var readAt: Date?
        /// The latest read returned any titles. False without Accessibility,
        /// when a real call and ChatGPT voice look the same.
        var titlesReadable = false
        /// A call-only title was seen. Sticky: switching away from the Meet
        /// tab mid-call must not demote it.
        var namedCall: MeetingPromptProvider?
        /// A known non-call site was focused. Sticky too, so ChatGPT voice
        /// does not prompt when the user clicks to another tab; only a
        /// call-only title, or a claimed call shortcut, can still win.
        var sawNonCallSite = false
        /// A Meet/Teams/Zoom app shortcut is the mic user for this session.
        /// Beats a non-call window in a different app of the same family.
        var claimedShortcut: MeetingPromptProvider?
        var readTask: Task<Void, Never>?
        var readToken = 0
        /// When this session's first title read started. The prompt is held
        /// only until `titleReadGiveUp`, not until a hung read returns.
        var readStartedAt: Date?
        /// Browser kinds the user said Not now to in this session.
        var declinedKinds: [String: Date] = [:]

        func verdict(now: Date, titleReadGiveUp: TimeInterval) -> BrowserCallTitleVerdict? {
            if let namedCall { return .call(provider: namedCall) }
            if let claimedShortcut { return .callSite(provider: claimedShortcut) }
            // Coming back to a Meet tab beats an early ChatGPT glance. A
            // random tab switch does not: that still needs sawNonCallSite.
            if case .call = latest { return latest }
            if case .callSite = latest { return latest }
            if sawNonCallSite { return .notCall }
            if latest == nil {
                guard let readStartedAt else { return nil }
                return BrowserCallEvidence.verdictBeforeTitleReadLands(
                    pendingFor: now.timeIntervalSince(readStartedAt),
                    giveUp: titleReadGiveUp
                )
            }
            return latest
        }
    }

    /// Turns one ad-hoc signal into a candidate. Native apps pass straight
    /// through. A browser has to show it is in a call first (see
    /// `BrowserCallEvidence`); until then this returns `nil`, schedules a
    /// re-check, and reports why the prompt is held back.
    func adHocCandidate(
        for signal: (provider: MeetingPromptProvider, reason: MeetingPromptReason),
        frontmostBundleID: String?,
        now: Date
    ) -> ScoredCandidate? {
        // `.googleMeet` from the signal mapping always means "some browser";
        // native apps never map to it.
        guard signal.provider == .googleMeet else {
            return micInputCandidate(for: signal.provider, reason: signal.reason, evidence: .nativeApp, now: now)
        }

        let families = browserFamiliesForEvidence(reason: signal.reason, frontmostBundleID: frontmostBundleID)
        let since = browserEvidenceStart(reason: signal.reason, families: families, now: now)
        let playingAudio = browserIsPlayingAudio(families: families)
        ensureCallShortcutLookup(frontmostBundleID)

        guard let verdict = currentBrowserTitleVerdict(
            families: families,
            frontmostBundleID: frontmostBundleID,
            now: now
        ) else {
            // The first title read of this session is still running, inside
            // `titleReadGiveUp`. It re-evaluates when it lands; if it hangs,
            // the re-check below ends the hold. Too brief to be worth a
            // suppression event.
            browserFirstTitleReadPending = true
            if let readStartedAt = browserTitles?.readStartedAt {
                scheduleBrowserEvidenceRecheck(
                    at: readStartedAt.addingTimeInterval(browserEvidenceTiming.titleReadGiveUp),
                    now: now
                )
            }
            return nil
        }

        switch verdict {
        case .call(let provider):
            detectedCallSession?.sawBrowserCallTitle = true
            detectedCallSession?.namedBrowserProvider = provider
        case .notCall:
            detectedCallSession?.sawBrowserNonCallSite = true
        case .callSite, .unknown:
            break
        }

        let decision = BrowserCallEvidence.decide(
            verdict: verdict,
            cameraInUse: cameraInUse,
            browserPlayingAudio: playingAudio,
            micSince: since,
            now: now,
            timing: browserEvidenceTiming
        )

        switch decision {
        case .prompt(let provider, let evidence):
            return micInputCandidate(
                for: provider ?? .googleMeet,
                reason: signal.reason,
                evidence: evidence,
                now: now
            )
        case .wait(let recheckAt):
            // Keep looking: the user may switch to the Meet tab, or the wait
            // may run out.
            scheduleBrowserEvidenceRecheck(at: recheckAt, now: now)
            recordSuppression(
                candidate: micInputCandidate(
                    for: .googleMeet,
                    reason: signal.reason,
                    evidence: pendingBrowserEvidence(verdict: verdict, playingAudio: playingAudio),
                    now: now
                ).candidate,
                reason: .awaitingCallEvidence,
                now: now
            )
            return nil
        case .notACall:
            // Only a call-only title can still change this, so look again
            // now and then rather than on the fast cadence.
            scheduleBrowserEvidenceRecheck(
                at: now.addingTimeInterval(browserEvidenceTiming.nonCallSiteRecheckInterval),
                now: now
            )
            recordSuppression(
                candidate: micInputCandidate(for: .googleMeet, reason: signal.reason, evidence: .nonCallSite, now: now).candidate,
                reason: .notACall,
                now: now
            )
            return nil
        }
    }

    /// The evidence a held-back browser prompt would carry, for telemetry.
    private func pendingBrowserEvidence(
        verdict: BrowserCallTitleVerdict,
        playingAudio: Bool
    ) -> MeetingPromptCallEvidence {
        if case .callSite = verdict { return .callSite }
        if playingAudio { return .micAndOutput }
        if cameraInUse { return .camera }
        return .micOnly
    }

    /// Browser families whose windows can name the call: the ones holding the
    /// mic, or for a camera-only signal the frontmost browser.
    /// Keyed by the app whose windows show the tab, so Safari's mic
    /// (`com.apple.WebKit`) and Safari in front (`com.apple.Safari`) are the
    /// same browser.
    private func browserFamiliesForEvidence(reason: MeetingPromptReason, frontmostBundleID: String?) -> Set<String> {
        if reason == .cameraInput {
            return Self.browserAppFamilies(for: [frontmostBundleID].compactMap { $0 })
        }
        return Self.browserAppFamilies(for: micActiveBundleIDs)
    }

    private static func browserAppFamilies<S: Sequence>(for bundleIDs: S) -> Set<String> where S.Element == String {
        Set(bundleIDs
            .compactMap(MeetingPromptProvider.browserFamily(forBundleID:))
            .map(MeetingPromptProvider.browserAppFamily(forBundleFamily:)))
    }

    /// When the wait for this browser signal started. For the mic, when a
    /// browser first held it. For the camera, the later of the camera coming
    /// on and this browser being the one in front, so a camera already on
    /// for another app does not let a browser skip the wait.
    private func browserEvidenceStart(reason: MeetingPromptReason, families: Set<String>, now: Date) -> Date {
        guard reason == .cameraInput else {
            return browserMicSince ?? now
        }
        if cameraEvidenceSince == nil || cameraEvidenceFamilies != families {
            cameraEvidenceFamilies = families
            cameraEvidenceSince = now
        }
        return max(cameraOnSince ?? now, cameraEvidenceSince ?? now)
    }

    private func browserIsPlayingAudio(families: Set<String>) -> Bool {
        !families.isDisjoint(with: Self.browserAppFamilies(for: browserOutputActiveBundleIDs))
    }

    /// What the window titles say for this browser session, with the sticky
    /// rules applied, or `nil` while the session's first read is running.
    /// Starts a background read when the last one is old enough; its result
    /// re-evaluates.
    private func currentBrowserTitleVerdict(
        families: Set<String>,
        frontmostBundleID: String?,
        now: Date
    ) -> BrowserCallTitleVerdict? {
        guard !families.isEmpty else { return .unknown }
        if var session = browserTitles, !session.families.isDisjoint(with: families) {
            // Same browser (another one may have joined or left): keep what
            // its titles already said.
            session.families = families
            browserTitles = session
        } else {
            // A different browser: its own titles, its own verdict.
            browserTitles?.readTask?.cancel()
            browserTitles = BrowserTitleSession(families: families, startedAt: now)
        }
        guard var session = browserTitles else { return nil }
        // Only a shortcut of the browser holding the mic can claim it: a Meet
        // shortcut in Helium says nothing about Chrome's mic.
        let isMicBrowser = { (bundleID: String) in !Self.browserAppFamilies(for: [bundleID]).isDisjoint(with: families) }
        let recent = recentCallShortcutActivation.flatMap { isMicBrowser($0.bundleID) ? $0 : nil }
        session.claimedShortcut = BrowserCallEvidence.claimedCallShortcut(
            frontmostShortcut: frontmostBundleID.flatMap { isMicBrowser($0) ? callShortcutProviders[$0] : nil },
            recentProvider: recent?.provider,
            recentActivationAt: recent?.at,
            sessionStartedAt: session.startedAt
        )
        browserTitles = session
        let readIsStale = session.readAt.map { now.timeIntervalSince($0) >= browserEvidenceTiming.titleReadSpacing } ?? true
        if session.namedCall == nil, session.readTask == nil, readIsStale {
            startBrowserTitleRead(families: families)
        }
        return session.verdict(now: now, titleReadGiveUp: browserEvidenceTiming.titleReadGiveUp)
    }

    private func startBrowserTitleRead(families: Set<String>) {
        browserTitleReadCounter += 1
        let token = browserTitleReadCounter
        let provider = browserWindowTitlesProvider
        browserTitles?.readToken = token
        if browserTitles?.readStartedAt == nil {
            browserTitles?.readStartedAt = Date()
        }
        evaluationsInFlight += 1
        browserTitles?.readTask = Task { @MainActor [weak self] in
            let titles = await provider(families)
            guard let self else { return }
            defer { self.finishEvaluation() }
            guard !Task.isCancelled, self.browserTitles?.readToken == token else { return }
            self.applyBrowserTitles(titles, now: Date())
            await self.evaluate()
        }
    }

    private func applyBrowserTitles(_ titles: [BrowserWindowTitle], now: Date) {
        guard var session = browserTitles else { return }
        let verdict = BrowserCallEvidence.classify(titles)
        session.readTask = nil
        session.readAt = now
        session.latest = verdict
        session.titlesReadable = !titles.isEmpty
        switch verdict {
        case .call(let provider):
            session.namedCall = provider
            session.sawNonCallSite = false
        case .callSite:
            // The user is on a call app now. An earlier non-call glance was
            // not the thing holding the mic.
            session.sawNonCallSite = false
        case .notCall:
            if now.timeIntervalSince(session.startedAt) <= browserEvidenceTiming.nonCallSiteStickyWindow {
                session.sawNonCallSite = true
            }
        case .unknown:
            break
        }
        browserTitles = session
    }

    private func scheduleBrowserEvidenceRecheck(at date: Date, now: Date) {
        if let pending = browserEvidenceRecheckAt, pending > now, pending <= date {
            return
        }
        browserEvidenceRecheckTask?.cancel()
        browserEvidenceRecheckAt = date
        let delay = max(0.05, date.timeIntervalSince(now))
        browserEvidenceRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.browserEvidenceRecheckAt = nil
            self.browserEvidenceRecheckTask = nil
            self.evaluationsInFlight += 1
            await self.evaluate()
            self.finishEvaluation()
        }
    }

    func cancelBrowserEvidenceRecheck() {
        browserEvidenceRecheckTask?.cancel()
        browserEvidenceRecheckTask = nil
        browserEvidenceRecheckAt = nil
    }

    /// No browser holds the mic. Keep the session for `micReleaseGrace` in
    /// case it comes straight back (Safari lets go of the mic while muted).
    func scheduleBrowserMicSessionEnd() {
        let grace = browserEvidenceTiming.micReleaseGrace
        guard grace > 0 else {
            endBrowserMicSession()
            return
        }
        browserMicEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.browserMicEndTask = nil
            guard !self.micActiveBundleIDs.contains(where: MeetingPromptProvider.isBrowserBundleID) else { return }
            self.endBrowserMicSession()
        }
    }

    /// A browser app came forward or launched. If it is a call shortcut, remember
    /// it so a calendar-opened Meet PWA is not vetoed by another Helium window.
    func noteCallShortcutActivation(bundleID: String, provider: MeetingPromptProvider, at: Date) {
        callShortcutProviders[bundleID] = provider
        callShortcutLookupDone.insert(bundleID)
        recentCallShortcutActivation = (bundleID: bundleID, provider: provider, at: at)
        scheduleEvaluation()
    }

    /// A call shortcut quit: it can no longer be the call that is starting.
    func noteCallShortcutTermination(bundleID: String) {
        guard recentCallShortcutActivation?.bundleID == bundleID else { return }
        recentCallShortcutActivation = nil
    }

    /// Classify the frontmost app's shortcut URL once, off this pass. The next
    /// evaluation uses the answer. A miss is remembered too, so a busy main
    /// browser is not read again on every mic poll.
    private func ensureCallShortcutLookup(_ bundleID: String?) {
        guard let bundleID, MeetingPromptProvider.isBrowserBundleID(bundleID) else { return }
        guard !callShortcutLookupDone.contains(bundleID) else { return }
        callShortcutLookupDone.insert(bundleID)
        let lookup = callShortcutProvider
        Task { @MainActor [weak self] in
            let site = await lookup(bundleID)
            guard let self else { return }
            if let site {
                self.callShortcutProviders[bundleID] = site
            }
            self.scheduleEvaluation()
        }
    }

    /// The browser session is over: forget the title verdict and stop
    /// re-checking. The next browser mic use starts its own wait.
    func endBrowserMicSession() {
        browserMicSince = nil
        browserMicEndTask?.cancel()
        browserMicEndTask = nil
        browserTitles?.readTask?.cancel()
        browserTitles = nil
        cancelBrowserEvidenceRecheck()
    }

    /// Providers a browser tab can be named after (see
    /// `BrowserCallEvidence.inCallProvider`).
    private static let browserNamedProviders: [MeetingPromptProvider] = [.googleMeet, .teams, .zoom]

    func browserCandidateIDs(besides id: String) -> [String] {
        (Self.browserNamedProviders.map { micCandidateID(for: $0) }
            + [Self.unverifiedBrowserCandidateID, Self.browserCallSiteCandidateID])
            .filter { $0 != id }
    }
}
