import Combine
import Foundation
import TranscriptedLabKit

enum LabSidebarSelection: Hashable {
    case newExperiment
    case run(UUID)
}

@MainActor
final class LabWorkspaceStore: ObservableObject {
    @Published var configuration: LabRunConfiguration
    @Published var reports: [LabRunReport]
    @Published var selection: LabSidebarSelection? = .newExperiment
    @Published var isRunning = false
    @Published var errorMessage: String?

    private let runner: LabExperimentRunner
    private let reportStore: LabReportStore

    init() {
        let repository = LabRepositoryLocator.locate()?.path ?? FileManager.default.currentDirectoryPath
        self.configuration = LabRunConfiguration.defaults(repositoryPath: repository)
        self.reportStore = LabReportStore()
        self.runner = LabExperimentRunner(reportStore: reportStore)
        self.reports = (try? reportStore.loadAll()) ?? []
    }

    func runExperiment() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        let snapshot = configuration
        Task {
            let report = await runner.run(snapshot)
            reports = (try? reportStore.loadAll()) ?? [report]
            selection = .run(report.id)
            isRunning = false
        }
    }

    func refresh() {
        do {
            reports = try reportStore.loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func report(id: UUID) -> LabRunReport? {
        reports.first { $0.id == id }
    }

    func previousComparableReport(for report: LabRunReport) -> LabRunReport? {
        reports
            .filter {
                $0.id != report.id
                    && $0.configuration.bench == report.configuration.bench
                    && $0.startedAt < report.startedAt
            }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    func comparison(for report: LabRunReport) -> LabRunComparison? {
        guard let baseline = previousComparableReport(for: report) else { return nil }
        return LabReportComparator.compare(baseline: baseline, candidate: report)
    }

    func duplicateConfiguration(from report: LabRunReport) {
        configuration = report.configuration
        configuration.name = report.configuration.name + " candidate"
        selection = .newExperiment
    }

    func delete(_ report: LabRunReport) {
        do {
            try reportStore.delete(id: report.id)
            refresh()
            selection = .newExperiment
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
