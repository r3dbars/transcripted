import SwiftUI

struct DebugWindow: View {
    @ObservedObject var monitor = AudioDebugMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text("Murmur Audio Debug Console")
                    .font(.title)
                    .bold()

                Divider()

                // Audio Levels
                AudioLevelsSection(monitor: monitor)

                Divider()

                // Buffer Flow
                BufferFlowSection(monitor: monitor)

                Divider()

                // Format Info
                FormatInfoSection(monitor: monitor)

                Divider()

                // Transcription Tests
                TranscriptionTestsSection(monitor: monitor)

                Divider()

                // Diagnostic Log
                DiagnosticLogSection(monitor: monitor)
            }
            .padding()
        }
        .frame(width: 700, height: 800)
    }
}

// MARK: - Audio Levels Section

struct AudioLevelsSection: View {
    @ObservedObject var monitor: AudioDebugMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AUDIO LEVELS")
                .font(.headline)

            LevelMeter(label: "Mic Input", level: monitor.micPeakLevel, color: .blue)
            LevelMeter(label: "System Audio", level: monitor.systemPeakLevel, color: .green)
            LevelMeter(label: "Mixed Output", level: monitor.mixedPeakLevel, color: .purple)

            if monitor.totalSamples > 0 {
                HStack {
                    if monitor.clippingPercentage > 10 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    Text("Clipping: \(monitor.clippedSamples)/\(monitor.totalSamples) (\(String(format: "%.1f", monitor.clippingPercentage))%)")
                        .font(.caption)
                        .foregroundColor(monitor.clippingPercentage > 10 ? .orange : .secondary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct LevelMeter: View {
    let label: String
    let level: Int16
    let color: Color

    var percentage: Double {
        Double(level) / Double(Int16.max)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .frame(width: 100, alignment: .leading)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 20)

                        Rectangle()
                            .fill(color)
                            .frame(width: geometry.size.width * percentage, height: 20)
                    }
                }
                .frame(height: 20)

                Text(String(level))
                    .font(.caption.monospaced())
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }
}

// MARK: - Buffer Flow Section

struct BufferFlowSection: View {
    @ObservedObject var monitor: AudioDebugMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BUFFER FLOW")
                .font(.headline)

            BufferFlowRow(label: "Mic Buffers", count: monitor.micBufferCount, rate: monitor.micBufferRate)
            BufferFlowRow(label: "System Buffers", count: monitor.systemBufferCount, rate: monitor.systemBufferRate)
            BufferFlowRow(label: "Ring Buffer Size", count: monitor.ringBufferSize, rate: nil)
            BufferFlowRow(label: "Mixed Sent", count: monitor.mixedBufferCount, rate: monitor.mixedBufferRate)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct BufferFlowRow: View {
    let label: String
    let count: Int
    let rate: Double?

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 150, alignment: .leading)

            Text(String(count))
                .font(.caption.monospaced())
                .frame(width: 80, alignment: .trailing)

            if let rate = rate {
                Text("(\(String(format: "%.0f", rate))/sec)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if rate > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }

            Spacer()
        }
    }
}

// MARK: - Format Info Section

struct FormatInfoSection: View {
    @ObservedObject var monitor: AudioDebugMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FORMAT INFO")
                .font(.headline)

            FormatRow(label: "Mic", format: monitor.micFormat)
            FormatRow(label: "System", format: monitor.systemFormat)
            FormatRow(label: "Output", format: monitor.outputFormat)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct FormatRow: View {
    let label: String
    let format: String

    var body: some View {
        HStack {
            Text("\(label):")
                .font(.caption)
                .frame(width: 70, alignment: .leading)

            Text(format)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

// MARK: - Transcription Tests Section

struct TranscriptionTestsSection: View {
    @ObservedObject var monitor: AudioDebugMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRANSCRIPTION TESTS")
                .font(.headline)

            TranscriptionRow(
                label: "Mic Only",
                active: monitor.micOnlyActive,
                text: monitor.micOnlyTranscription
            )

            TranscriptionRow(
                label: "System Only",
                active: monitor.systemOnlyActive,
                text: monitor.systemOnlyTranscription
            )

            TranscriptionRow(
                label: "Mixed",
                active: monitor.mixedActive,
                text: monitor.mixedTranscription
            )
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct TranscriptionRow: View {
    let label: String
    let active: Bool
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: active ? "checkmark.square" : "square")
                    .foregroundColor(active ? .green : .gray)

                Text(label)
                    .font(.caption)
                    .bold()

                Spacer()
            }

            Text(text.isEmpty ? "[No speech detected]" : text)
                .font(.caption)
                .foregroundColor(text.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .padding(.leading, 20)
        }
    }
}

// MARK: - Diagnostic Log Section

struct DiagnosticLogSection: View {
    @ObservedObject var monitor: AudioDebugMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DIAGNOSTIC LOG")
                    .font(.headline)

                Spacer()

                Button("Copy Summary") {
                    copySummaryToClipboard()
                }
                .font(.caption)

                Button("Copy Log") {
                    copyLogToClipboard()
                }
                .font(.caption)

                Button("Clear") {
                    monitor.logMessages.removeAll()
                }
                .font(.caption)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(monitor.logMessages) { msg in
                        LogMessageRow(message: msg)
                    }
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private func copySummaryToClipboard() {
        let summary = """
        === MURMUR DEBUG SUMMARY ===

        AUDIO LEVELS:
        1. Mic Input Level: \(monitor.micPeakLevel) (\(String(format: "%.1f", monitor.micLevelPercentage))%)
        2. System Audio Level: \(monitor.systemPeakLevel) (\(String(format: "%.1f", monitor.systemLevelPercentage))%)
        3. Mixed Output Level: \(monitor.mixedPeakLevel) (\(String(format: "%.1f", monitor.mixedLevelPercentage))%)

        BUFFER FLOW:
        4. Mic Buffers: \(monitor.micBufferCount) total (\(String(format: "%.0f", monitor.micBufferRate))/sec)
        5. System Buffers: \(monitor.systemBufferCount) total (\(String(format: "%.0f", monitor.systemBufferRate))/sec)
        6. Mixed Sent: \(monitor.mixedBufferCount) total (\(String(format: "%.0f", monitor.mixedBufferRate))/sec)
        7. Ring Buffer Size: \(monitor.ringBufferSize) samples

        CLIPPING:
        8. Clipped Samples: \(monitor.clippedSamples)/\(monitor.totalSamples) (\(String(format: "%.1f", monitor.clippingPercentage))%)

        FORMAT INFO:
        9. Mic Format: \(monitor.micFormat)
        10. System Format: \(monitor.systemFormat)
        11. Output Format: \(monitor.outputFormat)

        TRANSCRIPTION STATUS:
        12. Mic-Only Active: \(monitor.micOnlyActive ? "YES" : "NO")
        13. System-Only Active: \(monitor.systemOnlyActive ? "YES" : "NO")
        14. Mixed Active: \(monitor.mixedActive ? "YES" : "NO")
        15. Current Transcription: "\(monitor.mixedTranscription)"

        =============================
        """

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
    }

    private func copyLogToClipboard() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        let logText = monitor.logMessages.map { msg in
            "\(formatter.string(from: msg.timestamp)) \(msg.level.symbol) \(msg.message)"
        }.joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logText, forType: .string)
    }
}

struct LogMessageRow: View {
    let message: AudioDebugMonitor.LogMessage

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: message.timestamp)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(timeString)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)

            Text(message.level.symbol)
                .font(.caption)

            Text(message.message)
                .font(.caption)
                .foregroundColor(message.level.color)

            Spacer()
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Preview

struct DebugWindow_Previews: PreviewProvider {
    static var previews: some View {
        DebugWindow()
    }
}
