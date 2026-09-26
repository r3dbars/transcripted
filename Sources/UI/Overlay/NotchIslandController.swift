// NotchIslandController.swift
// The one notch island shared by dictation, meetings and the call-detected
// prompt (Settings › Dictation window › Notch island). Each controller keeps
// its own state machine, timers and actions and pushes a plain snapshot here
// (NotchIsland*Content). This composes them with NotchIslandPresentation,
// sizes the panel for the screen under the pointer with NotchIslandGeometry,
// grows it out of the notch (or down from the top edge of a display without
// one), and routes taps back to whichever controller owns them.

import AppKit

@MainActor
final class NotchIslandController: NotchIslandCallPromptPresenting {
    var dictationActionHandler: ((NotchIslandAction) -> Void)?
    var meetingActionHandler: ((NotchIslandAction) -> Void)?
    var callActionHandler: ((NotchIslandAction) -> Void)?
    /// The meeting pill's own hover rules (the saved dwell) still apply.
    var meetingHoverHandler: ((Bool) -> Void)?
    /// Right-click menu while a meeting records (Keep Controls Visible,
    /// Discard Recording…), the same one the meeting pill offers.
    var meetingMenuProvider: (() -> NSMenu?)?
    /// "Paste again" on the dictation that just landed.
    var onPasteLastDictation: (() -> Void)?
    /// The text of the dictation that just landed, for Copy and the preview.
    var lastDictationTextProvider: (() -> String?)?

    private static let growDuration: TimeInterval = 0.36
    private static let shrinkDuration: TimeInterval = 0.28
    private static let hoverOpenDelay: UInt64 = 120_000_000
    private static let hoverCloseDelay: UInt64 = 380_000_000
    private static let recentInsertLinger: UInt64 = 2_600_000_000
    private static let meterInterval: CFTimeInterval = 0.05

    private var dictation: NotchIslandDictationContent?
    private var meeting: NotchIslandMeetingContent?
    private var callPrompt: NotchIslandCallPromptContent?
    private var recentInsert: NotchIslandRecentInsert?
    private var targetApp: NSRunningApplication?
    private var listeningSince: Date?
    private var live = NotchIslandLiveValues()

    private var expanded = false
    private var collapsedStickyKey: String?
    private var isHovered = false
    private var lastLayout: NotchIslandLayout?
    private var lastWingWidths: (left: CGFloat, right: CGFloat) = (0, 0)
    private var lastMeterPush: CFTimeInterval = 0

    private var panel: NotchIslandPanel?
    private var islandView: NotchIslandView?
    /// The screen the island is on, kept while it is up so it never jumps.
    private var screen: NotchIslandScreenInfo?
    private var isShown = false
    private var targetFrame: NSRect?
    private var hideGeneration = 0
    private var hoverTask: Task<Void, Never>?
    private var recentInsertTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    static var isSelected: Bool {
        DictationOverlayPresentationPreferences.mode() == .notchIsland
    }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screen = nil
                self.targetFrame = nil
                if self.isShown { self.render(animated: false) }
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        hoverTask?.cancel()
        recentInsertTask?.cancel()
        tickTask?.cancel()
    }

    /// True while the pointer rests on the island (holds messages and the
    /// saved meeting, like hovering the old pills did).
    var isPointerOverIsland: Bool {
        guard isShown, let panel else { return false }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    // MARK: - Dictation

    func updateDictation(_ content: NotchIslandDictationContent?, targetApp: NSRunningApplication?) {
        if content?.phase == .starting || content == nil {
            listeningSince = nil
        }
        if content?.phase == .listening, listeningSince == nil {
            listeningSince = Date()
        }
        if content?.phase == .starting, recentInsert != nil {
            clearRecentInsert()
        }
        if case .loading(_, _, let progress?)? = content?.phase {
            live.loadingProgress = progress
        }
        let ended = content == nil && dictation != nil
        guard content != dictation || targetApp !== self.targetApp else { return }
        dictation = content
        self.targetApp = content == nil ? nil : targetApp
        if ended, recentInsert != nil {
            scheduleRecentInsertExpiry()
        }
        render()
        updateTicker()
    }

    func updateDictationLevel(_ level: Float) {
        guard isShown, dictation?.phase == .listening else { return }
        islandView?.pushDictationLevel(level)
    }

    /// The dictation landed. The island lingers on it after the "Pasted"
    /// beat so a hover can offer Copy and Paste again.
    func noteDictationInserted(title: String) {
        recentInsertTask?.cancel()
        recentInsertTask = nil
        recentInsert = NotchIslandRecentInsert(title: title, text: lastDictationTextProvider?())
        if dictation == nil {
            scheduleRecentInsertExpiry()
            render()
        }
    }

    // MARK: - Meetings

    func updateMeeting(_ content: NotchIslandMeetingContent?) {
        guard content != meeting else { return }
        meeting = content
        live.meetingElapsed = content?.duration ?? 0
        if case .transcribing(let progress, _)? = content?.phase {
            live.transcriptionProgress = progress ?? 0
        }
        render()
    }

    func updateMeetingLevels(mic: Float, system: Float) {
        guard isShown, meeting?.isRecording == true else { return }
        // Mic and call levels arrive as separate ticks; one push per beat
        // keeps the lanes scrolling at a steady pace.
        let now = CACurrentMediaTime()
        guard now - lastMeterPush >= Self.meterInterval else { return }
        lastMeterPush = now
        islandView?.pushMeetingLevels(mic: mic, system: system)
    }

    // MARK: - Call prompt

    func updateCallPrompt(_ content: NotchIslandCallPromptContent?) {
        if let content {
            live.callSecondsLeft = content.secondsLeft
        }
        guard content != callPrompt else {
            refreshLive()
            return
        }
        callPrompt = content
        render()
    }

    func updateCallPromptSeconds(_ secondsLeft: Int) {
        guard callPrompt != nil else { return }
        live.callSecondsLeft = secondsLeft
        refreshLive()
    }

    // MARK: - Rendering

    private func render(animated: Bool = true) {
        if NotchIslandPresentation.stickyKey(dictation: dictation, meeting: meeting, callPrompt: callPrompt) == nil {
            collapsedStickyKey = nil
        }
        let layout = NotchIslandPresentation.layout(
            dictation: dictation,
            meeting: meeting,
            callPrompt: callPrompt,
            recentInsert: recentInsert,
            expanded: expanded,
            collapsedStickyKey: collapsedStickyKey
        )
        lastLayout = layout
        guard !layout.isEmpty else {
            hide(animated: animated)
            return
        }

        let (panel, islandView) = ensurePanel()
        let screen = currentScreen()
        live.dictationElapsed = listeningSince.map { Date().timeIntervalSince($0) } ?? 0
        islandView.targetAppIcon = targetApp?.icon
        islandView.apply(layout, live: live)
        var edgeProgress: Double?
        if layout.showsEdgeProgress, case .transcribing(let progress?, _)? = meeting?.phase {
            edgeProgress = progress
        }
        islandView.setGeometry(screen: screen, hasDrop: layout.drop != nil, edgeProgress: edgeProgress)

        let widths = islandView.wingContentWidths
        lastWingWidths = widths
        let size = NotchIslandGeometry.islandSize(
            screen: screen,
            leftContent: widths.left,
            rightContent: widths.right,
            dropHeight: islandView.dropHeight
        )
        let frame = NotchIslandGeometry.frame(screen: screen, size: size)
        panel.hasShadow = layout.drop != nil

        if !isShown {
            isShown = true
            hideGeneration += 1
            if !panel.isVisible {
                panel.setFrame(NotchIslandGeometry.collapsedFrame(screen: screen), display: false)
            }
            islandView.setContentVisible(false, animated: false)
            panel.orderFrontRegardless()
            targetFrame = frame
            move(panel, to: frame, animated: animated) { [weak self] in
                guard let self, self.isShown else { return }
                self.islandView?.setContentVisible(true, animated: true)
            }
            updateTicker()
            return
        }
        guard targetFrame != frame else { return }
        targetFrame = frame
        move(panel, to: frame, animated: animated)
    }

    /// Timers and countdowns tick without rebuilding the island, unless a
    /// digit is added (9:59 → 10:00) and a wing needs more room.
    private func refreshLive() {
        guard isShown, let islandView else { return }
        live.dictationElapsed = listeningSince.map { Date().timeIntervalSince($0) } ?? 0
        islandView.updateLive(live)
        let widths = islandView.wingContentWidths
        if widths.left != lastWingWidths.left || widths.right != lastWingWidths.right {
            render()
        }
    }

    private func move(_ panel: NSPanel, to frame: NSRect, animated: Bool, completion: (() -> Void)? = nil) {
        guard animated, !NotchIslandPalette.reduceMotion else {
            panel.setFrame(frame, display: true)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.growDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            Task { @MainActor in completion?() }
        })
    }

    private func hide(animated: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        tickTask?.cancel()
        tickTask = nil
        expanded = false
        if isHovered {
            isHovered = false
            meetingHoverHandler?(false)
        }
        guard isShown, let panel, let islandView else { return }
        isShown = false
        targetFrame = nil
        panel.hasShadow = false
        hideGeneration += 1
        let generation = hideGeneration
        let finish = { [weak self] in
            guard let self, self.hideGeneration == generation, !self.isShown else { return }
            self.panel?.orderOut(nil)
            self.screen = nil
        }
        guard animated, !NotchIslandPalette.reduceMotion, let screen else {
            finish()
            return
        }
        islandView.setContentVisible(false, animated: true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.shrinkDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            panel.animator().setFrame(NotchIslandGeometry.collapsedFrame(screen: screen), display: true)
        }, completionHandler: {
            Task { @MainActor in finish() }
        })
    }

    private func ensurePanel() -> (NotchIslandPanel, NotchIslandView) {
        if let panel, let islandView { return (panel, islandView) }
        let initial = NSRect(x: 0, y: 0, width: NotchIslandGeometry.minimumTabWidth, height: NotchIslandGeometry.tabRowHeight)
        let panel = NotchIslandPanel(contentRect: initial, styleMask: [], backing: .buffered, defer: true)
        let view = NotchIslandView(frame: initial)
        view.autoresizingMask = [.width, .height]
        view.onAction = { [weak self] action in self?.handleAction(action) }
        view.onHoverChanged = { [weak self] hovered in self?.handleHover(hovered) }
        view.onBackgroundClick = { [weak self] in self?.handleBackgroundClick() }
        view.menuProvider = { [weak self] in self?.meetingMenuProvider?() }
        panel.contentView = view
        self.panel = panel
        self.islandView = view
        return (panel, view)
    }

    private func currentScreen() -> NotchIslandScreenInfo {
        if let screen { return screen }
        let mouse = NSEvent.mouseLocation
        let resolved: NotchIslandScreenInfo
        if let nsScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first {
            resolved = NotchIslandGeometry.screenInfo(
                frame: nsScreen.frame,
                safeAreaTop: nsScreen.safeAreaInsets.top,
                leftAuxiliaryWidth: nsScreen.auxiliaryTopLeftArea?.width,
                rightAuxiliaryWidth: nsScreen.auxiliaryTopRightArea?.width
            )
        } else {
            resolved = NotchIslandScreenInfo(
                frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                notchWidth: nil,
                rowHeight: NotchIslandGeometry.tabRowHeight
            )
        }
        screen = resolved
        return resolved
    }

    private func updateTicker() {
        guard isShown, dictation?.phase == .listening else {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshLive()
            }
        }
    }

    // MARK: - The dictation that just landed

    private func scheduleRecentInsertExpiry() {
        recentInsertTask?.cancel()
        recentInsertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.recentInsertLinger)
            // Reading it or reaching for Copy keeps it up.
            while let self, !Task.isCancelled, self.isHovered || self.expanded {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.recentInsertTask = nil
            self.recentInsert = nil
            self.render()
        }
    }

    private func clearRecentInsert() {
        recentInsertTask?.cancel()
        recentInsertTask = nil
        recentInsert = nil
    }

    // MARK: - Pointer and taps

    private func handleHover(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        meetingHoverHandler?(hovered)
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: hovered ? Self.hoverOpenDelay : Self.hoverCloseDelay)
            guard !Task.isCancelled else { return }
            if !hovered {
                // An exit can arrive while the shape resizes under a still
                // pointer; only close once the pointer has really left.
                while self?.isPointerOverIsland == true {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                }
            }
            guard let self, self.isHovered == hovered, self.expanded != hovered else { return }
            self.expanded = hovered
            self.render()
        }
    }

    private func handleBackgroundClick() {
        if case .message? = dictation?.phase {
            dictationActionHandler?(.dictationDismissMessage)
            return
        }
        let stickyKey = NotchIslandPresentation.stickyKey(dictation: dictation, meeting: meeting, callPrompt: callPrompt)
        if let stickyKey, lastLayout?.dropIsSticky == true {
            // Close the drop-down that opened by itself. It stays closed
            // until something new needs saying; a hover or click reopens it.
            collapsedStickyKey = stickyKey
            expanded = false
        } else {
            expanded.toggle()
        }
        hoverTask?.cancel()
        render()
    }

    private func handleAction(_ action: NotchIslandAction) {
        switch action.owner {
        case .dictation:
            dictationActionHandler?(action)
        case .meeting:
            meetingActionHandler?(action)
        case .callPrompt:
            callActionHandler?(action)
        case .island:
            handleOwnAction(action)
        }
    }

    private func handleOwnAction(_ action: NotchIslandAction) {
        switch action {
        case .copyLastDictation:
            guard let text = recentInsert?.text, !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            recentInsert?.title = "Copied"
            expanded = false
            render()
            scheduleRecentInsertExpiry()
        case .pasteLastDictation:
            clearRecentInsert()
            expanded = false
            render()
            onPasteLastDictation?()
        default:
            break
        }
    }
}
