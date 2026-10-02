// TranscriptedAppDelegate+SettingsActions.swift
// Settings actions, audio import queue and auto call detection preference

import SwiftUI
import AppKit
import AVFoundation
import Carbon
import Combine
import Darwin
import TranscriptedCore
import UniformTypeIdentifiers

extension TranscriptedAppDelegate {
    func startDictationFromSettings() {
        guard let session = appState.contextCapture.sessionController else { return }
        let sourceApp = resolvedSourceApp()
        sourceApp?.activate(options: [])
        session.startDictation(sourceApp: sourceApp, trigger: .menu)
    }

    func startMeetingFromSettings() {
        let sourceApp = resolvedSourceApp()
        sourceApp?.activate(options: [])
        Task {
            await appState.meetingSession.startRecording(trigger: .menu)
        }
    }

    func importAudioFileFromSettings() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .audiovisualContent]
        panel.prompt = "Transcribe"
        panel.message = "Choose audio files or Zoom/Teams recordings with an audio track. You can pick more than one."

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importAudioFiles(panel.urls)
    }

    /// Shared entry for the open panel and drag and drop onto Home. Files go
    /// through `pendingAudioImports` one at a time. While a meeting is
    /// capturing they wait: meetingSession.importAudioFile(from:) refuses
    /// then without touching `state` (see its entry guard), because failing
    /// through `state` would clear the capture-active gates for a recording
    /// that's still running. They start as soon as the recording stops.
    func importAudioFiles(_ urls: [URL]) {
        let importable = AudioImportQueue.importableFiles(from: urls)
        guard !importable.isEmpty else {
            // Deferred so a drop's drag session finishes before the modal
            // alert runs.
            DispatchQueue.main.async { [weak self] in
                self?.presentNoImportableFilesAlert(count: urls.count)
            }
            return
        }

        pendingAudioImports.add(importable)

        if appState.meetingSession.isCaptureSessionActive {
            startAudioImportsWhenCaptureEnds()
            DispatchQueue.main.async { [weak self] in
                self?.presentImportQueuedBehindActiveCaptureAlert(count: importable.count)
            }
            return
        }
        pumpAudioImports()
    }

    /// Home's Cancel stops the whole batch, not just the file being
    /// transcribed. The pump loop finds the queue empty after its current
    /// hand-off and ends.
    func cancelPendingAudioImports() {
        audioImportGeneration += 1
        pendingAudioImports = AudioImportQueue()
        audioImportCaptureEndSubscription = nil
    }

    private func pumpAudioImports() {
        guard audioImportPumpTask == nil else { return }
        audioImportPumpTask = Task { @MainActor [weak self] in
            while let self {
                guard !self.appState.meetingSession.isCaptureSessionActive else {
                    self.startAudioImportsWhenCaptureEnds()
                    break
                }
                guard let url = self.pendingAudioImports.popFirst() else { break }
                let generation = self.audioImportGeneration
                let started = await self.appState.meetingSession.importAudioFile(from: url)
                // A meeting can start while the previous file was being
                // copied. importAudioFile's entry guard refuses then; keep
                // the file and hand it over after that recording instead,
                // unless the user cancelled the batch in the meantime.
                if !started,
                   generation == self.audioImportGeneration,
                   self.appState.meetingSession.isCaptureSessionActive {
                    self.pendingAudioImports.pushFront(url)
                    self.startAudioImportsWhenCaptureEnds()
                    break
                }
            }
            self?.audioImportPumpTask = nil
        }
    }

    private func startAudioImportsWhenCaptureEnds() {
        guard audioImportCaptureEndSubscription == nil else { return }
        audioImportCaptureEndSubscription = appState.meetingSession.$state
            .map { MeetingSessionStateMachine.isCaptureSessionActive($0) }
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.audioImportCaptureEndSubscription = nil
                guard !self.pendingAudioImports.isEmpty else { return }
                self.pumpAudioImports()
            }
    }

    private func presentImportQueuedBehindActiveCaptureAlert(count: Int) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = count == 1
            ? "This file will transcribe after your meeting"
            : "These \(count) files will transcribe after your meeting"
        alert.informativeText = "Transcripted starts on them as soon as you stop recording. Keep Transcripted open until then."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentNoImportableFilesAlert(count: Int) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = count == 1
            ? "Transcripted can't transcribe that file"
            : "Transcripted can't transcribe those files"
        alert.informativeText = "Choose an audio file or a video recording with an audio track, like an .m4a, .mp3, .wav, or .mp4."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func pasteLastDictationFromSettings() {
        guard let latestText = DictationTranscriptStore.latestSavedText() else {
            PasteLastDictationFeedbackPresenter.shared.present(.noSavedDictation)
            return
        }

        let sourceApp = resolvedSourceApp()
        let pasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)
        sourceApp?.activate(options: [])
        let outcome = settingsTextPaster.paste(latestText, target: pasteTarget)
        PasteLastDictationFeedbackPresenter.shared.present(.presentation(for: outcome))
    }

    @available(macOS 14.0, *)
    func applyAutoCallDetectionPreference() {
        let isEnabled = AutoCallDetectionPreferences.isEnabled()
        defer { lastAppliedAutoCallDetectionEnabled = isEnabled }
        if isEnabled {
            // Turning detection off and on again is the way back from a
            // prompt the app learned to stop showing after repeated Not nows.
            if lastAppliedAutoCallDetectionEnabled == false {
                meetingPromptDetector.resetLearnedBackoff()
            }
            micActivityMonitor.start()
            cameraActivityMonitor.start()
        } else {
            micActivityMonitor.stop()
            cameraActivityMonitor.stop()
            // Drop any in-flight mic/output/camera candidates so a stale call can't prompt.
            meetingPromptDetector.updateMicInputUsers([])
            meetingPromptDetector.updateAudioOutputUsers([])
            meetingPromptDetector.updateBrowserOutputUsers([])
            meetingPromptDetector.updateCameraInUse(false)
        }
    }

    @available(macOS 14.0, *)
    func observeAutoCallDetectionPreference() {
        guard micPreferenceObserver == nil else { return }
        micPreferenceObserver = NotificationCenter.default.addObserver(
            forName: .autoCallDetectionPrefsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyAutoCallDetectionPreference()
            }
        }
    }
}
