import SwiftUI

struct UsageHealthSettingsSection: View {
    @State private var snapshot = UsageHealthStore.shared.snapshot()

    var body: some View {
        UsageHealthPanel(snapshot: snapshot)
            .onAppear { snapshot = UsageHealthStore.shared.snapshot() }
            .onReceive(NotificationCenter.default.publisher(for: UsageHealthStore.didChange).receive(on: RunLoop.main)) { _ in
                snapshot = UsageHealthStore.shared.snapshot()
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
                snapshot = UsageHealthStore.shared.snapshot(now: now)
            }
    }
}

/// Presentation accepts metadata only, so previews and support never need real captures.
struct UsageHealthPanel: View {
    let snapshot: UsageHealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage & health")
                .font(.headline)
            Text("This week on this Mac")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 28) {
                metric("Meetings saved", value: String(snapshot.meetings))
                metric("Dictations", value: String(snapshot.dictations))
                metric("Meeting time", value: minutesLabel(snapshot.meetingMinutesBucket))
            }
            HStack(spacing: 14) {
                Label("\(snapshot.qualityCounts["good", default: 0]) good", systemImage: "checkmark.circle")
                Label("\(snapshot.qualityCounts["degraded", default: 0]) degraded", systemImage: "exclamationmark.circle")
                Label("\(snapshot.qualityCounts["failed", default: 0]) failed", systemImage: "xmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if snapshot.qualityCounts["unknown", default: 0] > 0 {
                Text("\(snapshot.qualityCounts["unknown", default: 0]) captures have unknown quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Recent failures").font(.subheadline.weight(.medium))
            if snapshot.failures.isEmpty {
                Text("No failures recorded while usage stats were on.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.failures) { failure in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(failure.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.subheadline)
                        HStack(spacing: 8) {
                            Text(failure.time, style: .date)
                            Text(failure.time, style: .time)
                            Text("Version \(failure.version)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Usage stats share feature use, duration and count ranges, permission state, and error codes with an anonymous install ID. Your recordings, words, titles, names, and email stay private. Turning this off clears this local summary and unsent stats.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .accessibilityIdentifier("transcripted.settings.usage-health")
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func minutesLabel(_ bucket: String) -> String {
        switch bucket {
        case "0": return "< 1 min"
        case "1_14m": return "1–14 min"
        case "15_59m": return "15–59 min"
        case "1_2h": return "1–2 hr"
        case "3_9h": return "3–9 hr"
        default: return "10+ hr"
        }
    }
}
