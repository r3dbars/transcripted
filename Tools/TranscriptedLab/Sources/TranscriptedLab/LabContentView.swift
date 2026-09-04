import AppKit
import SwiftUI
import TranscriptedLabKit

struct LabContentView: View {
    @EnvironmentObject private var workspace: LabWorkspaceStore

    var body: some View {
        NavigationSplitView {
            List(selection: $workspace.selection) {
                Label("New Experiment", systemImage: "flask")
                    .tag(LabSidebarSelection.newExperiment)

                Section("Runs") {
                    ForEach(workspace.reports) { report in
                        RunSidebarRow(report: report)
                            .tag(LabSidebarSelection.run(report.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            switch workspace.selection ?? .newExperiment {
            case .newExperiment:
                LabExperimentView()
            case .run(let id):
                if let report = workspace.report(id: id) {
                    LabRunDetailView(report: report)
                } else {
                    ContentUnavailableView("Run not found", systemImage: "questionmark.folder")
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    workspace.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .alert("Transcripted Lab", isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } }
        )) {
            Button("OK") { workspace.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? "Unknown error")
        }
    }
}

private struct RunSidebarRow: View {
    let report: LabRunReport

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor(report.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.configuration.name)
                    .lineLimit(1)
                Text("\(report.configuration.bench.title) · \(report.scorecard.overallScore.map(String.init) ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LabExperimentView: View {
    @EnvironmentObject private var workspace: LabWorkspaceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcripted Lab")
                        .font(.largeTitle.bold())
                    Text("Change one arm, run the real Transcripted path, and compare it with the last run. Raw audio and transcripts stay in the local corpus or existing Transcripted folders.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Experiment") {
                    Form {
                        TextField("Name", text: $workspace.configuration.name)
                        Picker("Bench", selection: $workspace.configuration.bench) {
                            ForEach(LabBench.allCases) { bench in
                                Text(bench.title).tag(bench)
                            }
                        }
                        TextField("Transcripted repository", text: $workspace.configuration.repositoryPath)
                        LabeledContent("What it runs") {
                            Text(workspace.configuration.bench.summary)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .formStyle(.grouped)
                }

                benchControls

                GroupBox("Execution") {
                    Form {
                        TextField("Timeout (seconds)", value: $workspace.configuration.timeoutSeconds, format: .number)
                        Toggle("Reuse current app / tool build", isOn: $workspace.configuration.skipBuild)
                    }
                    .formStyle(.grouped)
                }

                HStack {
                    if workspace.isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Text("Experiment running…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run Experiment") {
                        workspace.runExperiment()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(workspace.isRunning)
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
        }
    }

    @ViewBuilder
    private var benchControls: some View {
        switch workspace.configuration.bench {
        case .runtimeSnapshot:
            GroupBox("Runtime Snapshot") {
                Form {
                    TextField("events.jsonl", text: $workspace.configuration.runtimeEventsPath)
                    TextField("Window (hours)", value: $workspace.configuration.runtimeWindowHours, format: .number)
                    Stepper("Minimum samples: \(workspace.configuration.minimumSamples)", value: $workspace.configuration.minimumSamples, in: 1...1_000)
                    Toggle("Fail on dictation fallback / retry events", isOn: $workspace.configuration.strictGates)
                }
                .formStyle(.grouped)
            }

        case .dictationStop:
            GroupBox("Dictation Arm") {
                Form {
                    Picker("Pipeline variant", selection: $workspace.configuration.dictationVariant) {
                        ForEach(DictationVariant.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("Repetitions per fixture: \(workspace.configuration.repetitions)", value: $workspace.configuration.repetitions, in: 1...100)
                    Picker("Encoder compute", selection: $workspace.configuration.encoderComputeMode) {
                        ForEach(EncoderComputeMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Finalization order", selection: $workspace.configuration.dictationFinalizationOrder) {
                        ForEach(DictationFinalizationOrder.allCases) { Text($0.title).tag($0) }
                    }
                    if workspace.configuration.dictationVariant == .chunked {
                        TextField("Chunk seconds", value: $workspace.configuration.chunkSeconds, format: .number)
                    }
                    Toggle("Include silence guardrail", isOn: $workspace.configuration.includeSilence)
                    Toggle("Simulate Auto Enter delay", isOn: $workspace.configuration.simulateAutoEnter)
                }
                .formStyle(.grouped)
            }

        case .transcriptionCorpus:
            GroupBox("Transcription Corpus") {
                Form {
                    TextField("Corpus root", text: $workspace.configuration.corpusRoot)
                    TextField("Meeting IDs (optional, comma-separated)", text: $workspace.configuration.corpusIDs)
                    TextField("Transcripted output directory", text: $workspace.configuration.corpusOutputDirectory)
                    TextField("Candidate map JSON (optional)", text: $workspace.configuration.corpusCandidateMap)
                    TextField("Minimum word recall", value: $workspace.configuration.corpusMinimumRecall, format: .number)
                    TextField("Minimum content-word recall", value: $workspace.configuration.corpusMinimumContentRecall, format: .number)
                }
                .formStyle(.grouped)
            }

        case .speakerIdentity:
            GroupBox("Speaker Arm") {
                Form {
                    Picker("Experiment", selection: $workspace.configuration.speakerMode) {
                        ForEach(SpeakerExperimentMode.allCases) { Text($0.title).tag($0) }
                    }
                    if workspace.configuration.speakerMode == .thresholdSweep {
                        Picker("Corpus", selection: $workspace.configuration.speakerCorpus) {
                            ForEach(SpeakerCorpus.allCases) { Text($0.title).tag($0) }
                        }
                        TextField("Meeting series (optional)", text: $workspace.configuration.speakerSeries)
                        TextField("Consolidation grid", text: $workspace.configuration.consolidationThresholds)
                        TextField("Cross-meeting match grid", text: $workspace.configuration.matchThresholds)
                        TextField("DER collar", value: $workspace.configuration.speakerCollar, format: .number)
                        Toggle("Allow partial local corpus", isOn: $workspace.configuration.allowPartialCorpus)
                    } else {
                        TextField("Frozen manifest", text: $workspace.configuration.speakerManifestPath)
                        TextField("Fingerprint cache root", text: $workspace.configuration.speakerInputRoot)
                        TextField("State directory (optional)", text: $workspace.configuration.speakerStateDirectory)
                        Picker("Phase", selection: $workspace.configuration.speakerResearchPhase) {
                            ForEach(SpeakerResearchPhase.allCases) { Text($0.title).tag($0) }
                        }
                        Stepper("Finalists: \(workspace.configuration.speakerTopK)", value: $workspace.configuration.speakerTopK, in: 1...32)
                    }
                }
                .formStyle(.grouped)
            }

        case .qa:
            GroupBox("QA Arm") {
                Form {
                    Picker("Mode", selection: $workspace.configuration.qaMode) {
                        ForEach(QABenchMode.allCases) { Text($0.title).tag($0) }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

private struct LabRunDetailView: View {
    @EnvironmentObject private var workspace: LabWorkspaceStore
    let report: LabRunReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(report.configuration.name)
                            .font(.largeTitle.bold())
                        Text("\(report.configuration.bench.title) · \(report.startedAt.formatted(date: .abbreviated, time: .standard))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(report.status.title)
                            .font(.headline)
                            .foregroundStyle(statusColor(report.status))
                        Text(report.scorecard.overallScore.map { "\($0) / 100" } ?? "No flat score")
                            .font(.title2.monospacedDigit())
                    }
                }

                Text(report.summary)

                if let comparison = workspace.comparison(for: report) {
                    GroupBox("Compared with previous \(report.configuration.bench.title)") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let delta = comparison.scoreDelta {
                                Text("Score \(delta >= 0 ? "+" : "")\(delta)")
                                    .font(.title3.bold())
                            }
                            ForEach(comparison.metricDeltas.prefix(8)) { metric in
                                HStack {
                                    Text(metric.label)
                                    Spacer()
                                    Text("\(metric.delta >= 0 ? "+" : "")\(metricValue(metric.delta)) \(metric.unit)")
                                        .monospacedDigit()
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                if !report.scorecard.hardGateFailures.isEmpty {
                    GroupBox("Hard failures") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(report.scorecard.hardGateFailures, id: \.self) {
                                Label($0, systemImage: "xmark.octagon.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(8)
                    }
                }

                if !report.scorecard.warnings.isEmpty {
                    GroupBox("Read this before choosing a winner") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(report.scorecard.warnings, id: \.self) {
                                Label($0, systemImage: "exclamationmark.triangle")
                            }
                        }
                        .padding(8)
                    }
                }

                if !report.scorecard.dimensions.isEmpty {
                    GroupBox("Scorecard") {
                        VStack(spacing: 10) {
                            ForEach(report.scorecard.dimensions) { dimension in
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dimension.label).bold()
                                        Text(dimension.explanation)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(dimension.score)")
                                        .font(.title3.monospacedDigit())
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                if !report.metrics.isEmpty {
                    GroupBox("Metrics") {
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                            GridRow {
                                Text("Metric").bold()
                                Text("Value").bold()
                                Text("Target").bold()
                                Text("Samples").bold()
                            }
                            Divider().gridCellColumns(4)
                            ForEach(report.metrics) { metric in
                                GridRow {
                                    Text(metric.label)
                                    Text("\(metricValue(metric.value)) \(metric.unit)").monospacedDigit()
                                    Text(metric.target.map { "\(metricValue($0)) \(metric.unit)" } ?? "—")
                                        .foregroundStyle(.secondary)
                                    Text(metric.sampleCount.map(String.init) ?? "—")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                if !report.artifacts.isEmpty {
                    GroupBox("Artifacts") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.artifacts) { artifact in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artifact.label).bold()
                                        Text(artifact.path)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.path)])
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                }

                if let command = report.command {
                    DisclosureGroup("Command") {
                        Text(command.displayCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }

                if let process = report.process, !process.stderrTail.isEmpty || !process.stdoutTail.isEmpty {
                    DisclosureGroup("Process output") {
                        VStack(alignment: .leading, spacing: 12) {
                            if !process.stdoutTail.isEmpty {
                                Text("stdout").bold()
                                Text(process.stdoutTail).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if !process.stderrTail.isEmpty {
                                Text("stderr").bold()
                                Text(process.stderrTail).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }
                }

                HStack {
                    Button("Duplicate as Candidate") {
                        workspace.duplicateConfiguration(from: report)
                    }
                    Spacer()
                    Button("Delete Run", role: .destructive) {
                        workspace.delete(report)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 960, alignment: .leading)
        }
    }
}

private func statusColor(_ status: LabRunStatus) -> Color {
    switch status {
    case .passed: return .green
    case .warning, .incomplete: return .orange
    case .failed: return .red
    case .cancelled: return .secondary
    }
}

private func metricValue(_ value: Double) -> String {
    if abs(value) >= 100 { return String(format: "%.0f", value) }
    if abs(value) >= 10 { return String(format: "%.1f", value) }
    return String(format: "%.3f", value)
}
