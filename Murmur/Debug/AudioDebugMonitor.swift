import Foundation
import SwiftUI

/// Real-time audio pipeline monitoring for debugging
class AudioDebugMonitor: ObservableObject {
    static let shared = AudioDebugMonitor()

    // MARK: - Audio Levels
    @Published var micPeakLevel: Int16 = 0
    @Published var systemPeakLevel: Int16 = 0
    @Published var mixedPeakLevel: Int16 = 0
    @Published var clippedSamples: Int = 0
    @Published var totalSamples: Int = 0

    // MARK: - Buffer Flow
    @Published var micBufferCount: Int = 0
    @Published var systemBufferCount: Int = 0
    @Published var mixedBufferCount: Int = 0
    @Published var ringBufferSize: Int = 0

    @Published var micBufferRate: Double = 0  // buffers/sec
    @Published var systemBufferRate: Double = 0
    @Published var mixedBufferRate: Double = 0

    // MARK: - Format Info
    @Published var micFormat: String = "Unknown"
    @Published var systemFormat: String = "Unknown"
    @Published var outputFormat: String = "16000Hz, Int16, 1ch"

    // MARK: - Transcription Status
    @Published var micOnlyTranscription: String = ""
    @Published var systemOnlyTranscription: String = ""
    @Published var mixedTranscription: String = ""

    @Published var micOnlyActive: Bool = false
    @Published var systemOnlyActive: Bool = false
    @Published var mixedActive: Bool = false

    // MARK: - Diagnostic Log
    @Published var logMessages: [LogMessage] = []
    private let maxLogMessages = 100

    // MARK: - Rate Calculation
    private var lastRateUpdate = Date()
    private var micBuffersSinceLastUpdate = 0
    private var systemBuffersSinceLastUpdate = 0
    private var mixedBuffersSinceLastUpdate = 0

    struct LogMessage: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String

        enum Level {
            case info, warning, error, success

            var symbol: String {
                switch self {
                case .info: return "ℹ️"
                case .warning: return "⚠️"
                case .error: return "❌"
                case .success: return "✓"
                }
            }

            var color: Color {
                switch self {
                case .info: return .blue
                case .warning: return .orange
                case .error: return .red
                case .success: return .green
                }
            }
        }
    }

    private init() {
        // Start rate calculation timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateRates()
        }
    }

    // MARK: - Public Methods

    func recordMicBuffer(frameLength: Int, peakLevel: Int16, format: String) {
        DispatchQueue.main.async {
            self.micBufferCount += 1
            self.micBuffersSinceLastUpdate += 1
            self.micPeakLevel = max(self.micPeakLevel, peakLevel)
            if self.micFormat != format {
                self.micFormat = format
            }
        }
    }

    func recordSystemBuffer(frameLength: Int, peakLevel: Int16, format: String) {
        DispatchQueue.main.async {
            self.systemBufferCount += 1
            self.systemBuffersSinceLastUpdate += 1
            self.systemPeakLevel = max(self.systemPeakLevel, peakLevel)
            if self.systemFormat != format {
                self.systemFormat = format
            }
        }
    }

    func recordMixedBuffer(peakLevel: Int16, clippedCount: Int, totalCount: Int) {
        DispatchQueue.main.async {
            self.mixedBufferCount += 1
            self.mixedBuffersSinceLastUpdate += 1
            self.mixedPeakLevel = max(self.mixedPeakLevel, peakLevel)
            self.clippedSamples += clippedCount
            self.totalSamples += totalCount
        }
    }

    func updateRingBufferSize(_ size: Int) {
        DispatchQueue.main.async {
            self.ringBufferSize = size
        }
    }

    func updateMicTranscription(_ text: String) {
        DispatchQueue.main.async {
            self.micOnlyTranscription = text
        }
    }

    func updateSystemTranscription(_ text: String) {
        DispatchQueue.main.async {
            self.systemOnlyTranscription = text
        }
    }

    func updateMixedTranscription(_ text: String) {
        DispatchQueue.main.async {
            self.mixedTranscription = text
        }
    }

    func log(_ message: String, level: LogMessage.Level = .info) {
        DispatchQueue.main.async {
            let logMsg = LogMessage(timestamp: Date(), level: level, message: message)
            self.logMessages.insert(logMsg, at: 0)
            if self.logMessages.count > self.maxLogMessages {
                self.logMessages.removeLast()
            }
        }
    }

    func reset() {
        DispatchQueue.main.async {
            self.micPeakLevel = 0
            self.systemPeakLevel = 0
            self.mixedPeakLevel = 0
            self.clippedSamples = 0
            self.totalSamples = 0

            self.micBufferCount = 0
            self.systemBufferCount = 0
            self.mixedBufferCount = 0

            self.micOnlyTranscription = ""
            self.systemOnlyTranscription = ""
            self.mixedTranscription = ""

            self.micOnlyActive = false
            self.systemOnlyActive = false
            self.mixedActive = false

            self.logMessages.removeAll()
        }
    }

    // MARK: - Private Methods

    private func updateRates() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRateUpdate)

        if elapsed > 0 {
            DispatchQueue.main.async {
                self.micBufferRate = Double(self.micBuffersSinceLastUpdate) / elapsed
                self.systemBufferRate = Double(self.systemBuffersSinceLastUpdate) / elapsed
                self.mixedBufferRate = Double(self.mixedBuffersSinceLastUpdate) / elapsed
            }
        }

        lastRateUpdate = now
        micBuffersSinceLastUpdate = 0
        systemBuffersSinceLastUpdate = 0
        mixedBuffersSinceLastUpdate = 0
    }

    // MARK: - Computed Properties

    var clippingPercentage: Double {
        guard totalSamples > 0 else { return 0 }
        return (Double(clippedSamples) / Double(totalSamples)) * 100
    }

    var micLevelPercentage: Double {
        Double(micPeakLevel) / Double(Int16.max) * 100
    }

    var systemLevelPercentage: Double {
        Double(systemPeakLevel) / Double(Int16.max) * 100
    }

    var mixedLevelPercentage: Double {
        Double(mixedPeakLevel) / Double(Int16.max) * 100
    }
}
