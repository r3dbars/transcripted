import Foundation

/// Tracks independently admitted archive work through its main-actor apply.
/// Waiting observes that work; it never cancels it or changes queue occupancy.
@MainActor
final class FailedAudioArchiveJobs {
    struct Completion: Sendable {
        fileprivate let jobs: [Task<Void, Never>]

        func wait() async {
            for job in jobs {
                await job.value
            }
        }
    }

    private var jobs: [UUID: Task<Void, Never>] = [:]

    func schedule<Output: Sendable>(
        work: @escaping @Sendable () -> Output,
        apply: @escaping @MainActor (Output) -> Void
    ) {
        // An invocation is distinct even when its business ID or output matches
        // an earlier job. Admission happens before this actor can yield.
        let invocation = UUID()
        let job = Task { @MainActor [weak self] in
            defer { self?.jobs.removeValue(forKey: invocation) }
            let output = await Task.detached(priority: .utility, operation: work).value
            apply(output)
        }
        jobs[invocation] = job
    }

    /// Synchronously starts a wait for exactly the jobs admitted so far.
    /// Later admissions are excluded even if `wait()` is called afterward.
    func beginWaitingForScheduledJobs() -> Completion {
        Completion(jobs: Array(jobs.values))
    }
}
