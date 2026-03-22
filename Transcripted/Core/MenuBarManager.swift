import AppKit
import Combine

// MARK: - Menu Bar Setup & Management

@available(macOS 26.0, *)
extension AppDelegate {

    /// Build and configure the status bar menu
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Transcripted")
            button.imagePosition = .imageLeading
            button.action = #selector(statusBarClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.delegate = self

        // Section 1: Stats rows (custom views)
        let todayRow = MenuBarStatRow(icon: "clock", iconColor: .labelColor, primary: "Today: No meetings")
        let todayItem = NSMenuItem()
        todayItem.view = todayRow
        todayStatRow = todayRow
        menu.addItem(todayItem)

        let weekRow = MenuBarStatRow(icon: "calendar", iconColor: terracottaColor, primary: "This Week: 0 meetings")
        let weekItem = NSMenuItem()
        weekItem.view = weekRow
        weekStatRow = weekRow
        menu.addItem(weekItem)

        let streakRow = MenuBarStatRow(icon: "flame", iconColor: .systemOrange, primary: "Streak: 0 days")
        let streakItem = NSMenuItem()
        streakItem.view = streakRow
        streakStatRow = streakRow
        menu.addItem(streakItem)

        // Processing status (conditional)
        let processing = NSMenuItem(title: "Transcribing...", action: nil, keyEquivalent: "")
        processing.isHidden = true
        processing.isEnabled = false
        processing.image = Self.menuIcon("waveform")
        processingMenuItem = processing
        menu.addItem(processing)

        menu.addItem(NSMenuItem.separator())

        // Section 2: Actions
        let toggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "R")
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.image = Self.menuIcon("record.circle")
        recordingToggleMenuItem = toggleItem
        menu.addItem(toggleItem)

        let transcriptsItem = NSMenuItem(title: "Open Transcripts", action: #selector(openTranscriptsFolder), keyEquivalent: "")
        transcriptsItem.image = Self.menuIcon("folder")
        menu.addItem(transcriptsItem)

        let failed = NSMenuItem(title: "Failed — Retry...", action: #selector(openFailedTranscriptions), keyEquivalent: "")
        failed.isHidden = true
        failed.image = Self.menuIcon("exclamationmark.triangle")
        failedMenuItem = failed
        menu.addItem(failed)

        menu.addItem(NSMenuItem.separator())

        // Section 3: Footer
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = Self.menuIcon("gearshape")
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Transcripted", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = Self.menuIcon("power")
        menu.addItem(quitItem)

        #if DEBUG
        menu.addItem(NSMenuItem.separator())
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let debugMenu = NSMenu()
        debugMenu.addItem(NSMenuItem(title: "Reset Onboarding", action: #selector(resetOnboarding), keyEquivalent: ""))
        debugMenu.addItem(NSMenuItem(title: "Test Naming Tray", action: #selector(testNamingTray), keyEquivalent: ""))
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)
        #endif

        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuBarWillOpen(_ menu: NSMenu) {
        let stats = StatsService.shared

        // Update stat rows
        let todayCount = stats.todayRecordings
        if todayCount > 0 {
            todayStatRow?.update(
                primary: "Today: \(todayCount) meeting\(todayCount == 1 ? "" : "s")",
                secondary: stats.formattedTodayDuration
            )
        } else {
            todayStatRow?.update(primary: "Today: No meetings")
        }

        let weekCount = stats.weekRecordings
        if weekCount > 0 {
            weekStatRow?.update(
                primary: "This Week: \(weekCount) meeting\(weekCount == 1 ? "" : "s")",
                secondary: stats.formattedWeekDuration
            )
        } else {
            weekStatRow?.update(primary: "This Week: 0 meetings")
        }

        let streak = stats.currentStreak
        streakStatRow?.update(primary: "Streak: \(streak) day\(streak == 1 ? "" : "s")")

        // Update recording toggle with live duration
        if let audio = audio, audio.isRecording {
            let totalSeconds = Int(audio.recordingDuration)
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            recordingToggleMenuItem?.title = String(format: "Stop Recording · %d:%02d", minutes, seconds)
        }

        // Conditional: failed transcriptions
        let failedCount = failedTranscriptionManager?.failedTranscriptions.count ?? 0
        if failedCount > 0 {
            failedMenuItem?.title = "\(failedCount) Failed — Retry..."
            failedMenuItem?.isHidden = false
        } else {
            failedMenuItem?.isHidden = true
        }

        // Conditional: processing status
        if let status = taskManager?.displayStatus, status.isProcessing {
            let pct = Int(status.progress * 100)
            processingMenuItem?.title = "\(status.statusText) \(pct)%"
            processingMenuItem?.isHidden = false
        } else {
            processingMenuItem?.isHidden = true
        }
    }

    // MARK: - Status Bar Title

    func updateStatusBarTitle() {
        guard let button = statusItem?.button else { return }
        let stats = StatsService.shared
        let todayCount = stats.todayRecordings

        if todayCount == 0 {
            button.title = ""
            return
        }

        let duration = StatsService.formatDurationCompact(stats.todayDurationSeconds)
        let attributed = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        attributed.append(NSAttributedString(
            string: "\(todayCount)",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        ))
        attributed.append(NSAttributedString(
            string: " · ",
            attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        ))
        attributed.append(NSAttributedString(
            string: duration,
            attributes: [.font: font, .foregroundColor: terracottaColor]
        ))

        button.attributedTitle = attributed
    }

    /// Create a 14pt SF Symbol for menu items
    static func menuIcon(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - Duration Timer

    func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let audio = self.audio, audio.isRecording else { return }
                let totalSeconds = Int(audio.recordingDuration)
                let minutes = totalSeconds / 60
                let seconds = totalSeconds % 60

                // Update status bar with live duration
                let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                let title = NSAttributedString(
                    string: String(format: "%d:%02d", minutes, seconds),
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]
                )
                self.statusItem?.button?.attributedTitle = title

                // Update menu item if open
                self.recordingToggleMenuItem?.title = String(format: "Stop Recording · %d:%02d", minutes, seconds)
            }
        }
    }

    func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    /// Subscribe to Audio.isRecording to update menu bar icon dynamically
    func subscribeToRecordingState() {
        guard let aud = audio else { return }
        aud.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self = self, let button = self.statusItem?.button else { return }
                if isRecording {
                    button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
                    button.contentTintColor = .systemRed
                    button.title = ""
                    self.recordingToggleMenuItem?.title = "Stop Recording"
                    self.recordingToggleMenuItem?.image = Self.menuIcon("stop.circle")
                    self.startDurationTimer()
                } else {
                    button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Transcripted")
                    button.contentTintColor = nil
                    self.recordingToggleMenuItem?.title = "Start Recording"
                    self.recordingToggleMenuItem?.image = Self.menuIcon("record.circle")
                    self.stopDurationTimer()
                    self.updateStatusBarTitle()
                }
            }
            .store(in: &cancellables)
    }
}
