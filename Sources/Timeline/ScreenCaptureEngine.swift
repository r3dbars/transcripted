// ScreenCaptureEngine.swift
// Phase 1 timeline capture engine skeleton. Screenshots stay local.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum TimelineCaptureCadence {
    static let screenshotInterval: TimeInterval = 10
    static let permissionProbeInterval: TimeInterval = 60
    static let wakeResumeDelay: TimeInterval = 5
    static let unlockResumeDelay: TimeInterval = 0.5
    static let jpegQuality: CGFloat = 0.85
    static let targetHeightPixels = TimelineCaptureScaling.targetHeightPixels
}

enum ScreenCapturePauseReason: String, Equatable {
    case sleep
    case screenLock
    case screensaver
    case permissionDenied
    case permissionRevoked
    case userPause
}

enum ScreenCaptureEngineState: Equatable {
    case idle
    case starting
    case capturing
    case paused(ScreenCapturePauseReason)
}

struct TimelineScreenshotRecord: Equatable {
    let capturedAt: Date
    let fileURL: URL
    let fileSize: Int64
    let idleSecondsAtCapture: TimeInterval
    let appBundleIdentifier: String?
    let appName: String?
    let windowTitle: String?
    let displayID: CGDirectDisplayID?
}

struct TimelineScreenshotCaptureRequest {
    let display: TimelineDisplay
    let blockedBundleIdentifiers: Set<String>
    let outputSize: CGSize
}

enum TimelineCaptureBlocklist {
    static func normalizedBundleIdentifiers(_ rawValues: [String]) -> Set<String> {
        Set(
            rawValues
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

struct TimelineCaptureStateMachine {
    private(set) var state: ScreenCaptureEngineState = .idle

    mutating func start(permissionGranted: Bool) {
        state = permissionGranted ? .starting : .paused(.permissionDenied)
    }

    mutating func markCapturing() {
        state = .capturing
    }

    mutating func pause(_ reason: ScreenCapturePauseReason) {
        state = .paused(reason)
    }

    mutating func stop() {
        state = .idle
    }

    mutating func resume(permissionGranted: Bool) {
        guard case .paused = state else { return }
        state = permissionGranted ? .starting : .paused(.permissionDenied)
    }

    static func resumeDelay(after reason: ScreenCapturePauseReason) -> TimeInterval? {
        switch reason {
        case .sleep:
            return TimelineCaptureCadence.wakeResumeDelay
        case .screenLock, .screensaver:
            return TimelineCaptureCadence.unlockResumeDelay
        case .permissionDenied, .permissionRevoked, .userPause:
            return nil
        }
    }
}

// Mutable engine state is confined to `queue`; detached capture work re-enters through that queue.
final class ScreenCaptureEngine: @unchecked Sendable {
    typealias PermissionChecker = () -> Bool
    typealias BlocklistProvider = () -> [String]
    typealias RecordSink = (TimelineScreenshotRecord) -> Void
    typealias FailureObserver = (Error) -> Void

    private let queue = DispatchQueue(label: "Transcripted.Timeline.ScreenCaptureEngine")
    private let displayTracker: ActiveDisplayTracker
    private let idleSnapshotProvider: () -> InputIdleSnapshot
    private let foregroundAppSampler: ForegroundAppSampler
    private let permissionChecker: PermissionChecker
    private let blocklistProvider: BlocklistProvider
    private let screenshotStore: LocalTimelineScreenshotStore
    private let recordSink: RecordSink
    private let onFailure: FailureObserver?
    private let onStateChange: (ScreenCaptureEngineState) -> Void

    private var stateMachine = TimelineCaptureStateMachine()
    private var timer: DispatchSourceTimer?
    private var observerTokens: [NSObjectProtocol] = []
    private var distributedObserverTokens: [NSObjectProtocol] = []
    private var captureInFlight = false

    init(
        displayTracker: ActiveDisplayTracker = ActiveDisplayTracker(),
        idleSnapshotProvider: @escaping () -> InputIdleSnapshot = { InputIdleSnapshot.current() },
        foregroundAppSampler: ForegroundAppSampler = ForegroundAppSampler(),
        permissionChecker: @escaping PermissionChecker = { CGPreflightScreenCaptureAccess() },
        blocklistProvider: @escaping BlocklistProvider = { [] },
        screenshotStore: LocalTimelineScreenshotStore = LocalTimelineScreenshotStore(),
        recordSink: @escaping RecordSink = { _ in },
        onFailure: FailureObserver? = nil,
        onStateChange: @escaping (ScreenCaptureEngineState) -> Void = { _ in }
    ) {
        self.displayTracker = displayTracker
        self.idleSnapshotProvider = idleSnapshotProvider
        self.foregroundAppSampler = foregroundAppSampler
        self.permissionChecker = permissionChecker
        self.blocklistProvider = blocklistProvider
        self.screenshotStore = screenshotStore
        self.recordSink = recordSink
        self.onFailure = onFailure
        self.onStateChange = onStateChange
    }

    var currentState: ScreenCaptureEngineState {
        queue.sync { stateMachine.state }
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopTimerLocked()
            self.removeSystemObserversLocked()
            self.transitionLocked { $0.stop() }
        }
    }

    func pauseForUser() {
        queue.async { [weak self] in
            self?.pauseLocked(.userPause)
        }
    }

    func resumeFromUserPause() {
        queue.async { [weak self] in
            guard let self, self.stateMachine.state == .paused(.userPause) else { return }
            self.resumeLocked(after: .userPause)
        }
    }

    private func startLocked() {
        transitionLocked { $0.start(permissionGranted: permissionChecker()) }
        guard stateMachine.state == .starting else { return }
        installSystemObserversLocked()
        startTimerLocked(interval: TimelineCaptureCadence.screenshotInterval)
        transitionLocked { $0.markCapturing() }
    }

    private func pauseLocked(_ reason: ScreenCapturePauseReason) {
        stopTimerLocked()
        transitionLocked { $0.pause(reason) }
    }

    private func resumeLocked(after reason: ScreenCapturePauseReason) {
        guard reason != .userPause else {
            startLocked()
            return
        }

        let delay = TimelineCaptureStateMachine.resumeDelay(after: reason) ?? TimelineCaptureCadence.permissionProbeInterval
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if case .paused(reason) = self.stateMachine.state {
                self.startLocked()
            }
        }
    }

    private func startTimerLocked(interval: TimeInterval) {
        stopTimerLocked()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in
            self?.captureTickLocked()
        }
        source.resume()
        timer = source
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func captureTickLocked() {
        guard stateMachine.state == .capturing, !captureInFlight else { return }
        guard permissionChecker() else {
            pauseLocked(.permissionRevoked)
            resumeLocked(after: .permissionRevoked)
            return
        }
        guard let display = displayTracker.selectedDisplay() else { return }

        captureInFlight = true
        let request = TimelineScreenshotCaptureRequest(
            display: display,
            blockedBundleIdentifiers: TimelineCaptureBlocklist.normalizedBundleIdentifiers(blocklistProvider()),
            outputSize: TimelineCaptureScaling.targetPixelSize(for: display)
        )
        let idleSnapshot = idleSnapshotProvider()
        let foregroundSnapshot = foregroundAppSampler.currentSnapshot()

        Task.detached(priority: .utility) { [weak self] in
            do {
                let record = try await self?.captureAndStore(
                    request: request,
                    idleSnapshot: idleSnapshot,
                    foregroundSnapshot: foregroundSnapshot
                )
                self?.queue.async {
                    self?.captureInFlight = false
                    if let record {
                        self?.recordSink(record)
                    }
                }
            } catch {
                self?.queue.async {
                    guard let self else { return }
                    self.captureInFlight = false
                    self.onFailure?(error)
                    if self.isLikelyPermissionError(error) || !self.permissionChecker() {
                        self.pauseLocked(.permissionRevoked)
                        self.resumeLocked(after: .permissionRevoked)
                    }
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private func captureAndStore(
        request: TimelineScreenshotCaptureRequest,
        idleSnapshot: InputIdleSnapshot,
        foregroundSnapshot: ForegroundAppSnapshot
    ) async throws -> TimelineScreenshotRecord {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == request.display.id }) ?? content.displays.first else {
            throw TimelineCaptureError.noDisplayAvailable
        }

        let excludedApps = content.applications.filter { app in
            request.blockedBundleIdentifiers.contains(app.bundleIdentifier)
        }

        let filter = SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(request.outputSize.width)
        configuration.height = Int(request.outputSize.height)
        configuration.showsCursor = true
        configuration.scalesToFit = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let fileURL = try screenshotStore.writeJPEG(image, capturedAt: idleSnapshot.capturedAt)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return TimelineScreenshotRecord(
            capturedAt: idleSnapshot.capturedAt,
            fileURL: fileURL,
            fileSize: fileSize,
            idleSecondsAtCapture: idleSnapshot.idleSeconds,
            appBundleIdentifier: foregroundSnapshot.bundleIdentifier,
            appName: foregroundSnapshot.appName,
            windowTitle: foregroundSnapshot.windowTitle,
            displayID: request.display.id
        )
    }

    private func installSystemObserversLocked() {
        guard observerTokens.isEmpty, distributedObserverTokens.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.pauseLocked(.sleep) }
            }
        )
        observerTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.resumeLocked(after: .sleep) }
            }
        )

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObserverTokens.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.pauseLocked(.screenLock) }
            }
        )
        distributedObserverTokens.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.resumeLocked(after: .screenLock) }
            }
        )
        distributedObserverTokens.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screensaver.didstart"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.pauseLocked(.screensaver) }
            }
        )
        distributedObserverTokens.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screensaver.didstop"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.resumeLocked(after: .screensaver) }
            }
        )
    }

    private func removeSystemObserversLocked() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerTokens.forEach { workspaceCenter.removeObserver($0) }
        observerTokens.removeAll()

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObserverTokens.forEach { distributedCenter.removeObserver($0) }
        distributedObserverTokens.removeAll()
    }

    private func transitionLocked(_ mutate: (inout TimelineCaptureStateMachine) -> Void) {
        let previous = stateMachine.state
        mutate(&stateMachine)
        if previous != stateMachine.state {
            onStateChange(stateMachine.state)
        }
    }

    private func isLikelyPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let text = "\(nsError.domain) \(nsError.localizedDescription)".lowercased()
        return text.contains("permission") || text.contains("privacy") || text.contains("tcc")
    }

    deinit {
        stopTimerLocked()
        removeSystemObserversLocked()
    }
}

enum TimelineCaptureError: Error, Equatable {
    case noDisplayAvailable
    case imageDestinationUnavailable
    case imageEncodingFailed
}

final class LocalTimelineScreenshotStore {
    private let fileManager: FileManager
    private let rootDirectory: URL

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL = FileManager.default.transcriptedTimelineScreenshotsDir
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
    }

    func writeJPEG(_ image: CGImage, capturedAt: Date) throws -> URL {
        let day = Self.dayFormatter.string(from: capturedAt)
        let directory = rootDirectory.appendingPathComponent(day, isDirectory: true)
        try fileManager.createPrivateDirectory(at: directory)

        let milliseconds = Int64((capturedAt.timeIntervalSince1970 * 1000).rounded())
        let url = directory.appendingPathComponent("\(milliseconds).jpg", isDirectory: false)
        let data = try Self.jpegData(from: image)
        try data.write(to: url, options: [.atomic])
        fileManager.restrictFileToOwnerOnly(at: url)
        return url
    }

    static func jpegData(from image: CGImage, quality: CGFloat = TimelineCaptureCadence.jpegQuality) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TimelineCaptureError.imageDestinationUnavailable
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw TimelineCaptureError.imageEncodingFailed
        }
        return data as Data
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@MainActor
final class TimelineEngineController {
    private let makeEngine: () -> ScreenCaptureEngine
    private var engine: ScreenCaptureEngine?

    private(set) var state: ScreenCaptureEngineState = .idle

    init(makeEngine: @escaping () -> ScreenCaptureEngine = { ScreenCaptureEngine() }) {
        self.makeEngine = makeEngine
    }

    func startIfAllowed(enabled: Bool, onboardingCompleted: Bool, permissionGranted: Bool) {
        guard enabled, onboardingCompleted, permissionGranted else {
            stop()
            state = permissionGranted ? .idle : .paused(.permissionDenied)
            return
        }

        if engine == nil {
            engine = makeEngine()
        }
        engine?.start()
        state = engine?.currentState ?? .starting
    }

    func stop() {
        engine?.stop()
        engine = nil
        state = .idle
    }
}

extension FileManager {
    var transcriptedTimelineScreenshotsDir: URL {
        let url = transcriptedAppSupportDir
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
        return ensuredTimelinePrivateDirectory(at: url, context: "Transcripted timeline screenshots")
    }

    private func ensuredTimelinePrivateDirectory(at url: URL, context: String) -> URL {
        ensurePrivateDirectory(at: url, context: context)
        return url
    }
}
