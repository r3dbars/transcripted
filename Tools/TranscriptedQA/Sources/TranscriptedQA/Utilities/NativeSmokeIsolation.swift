import Darwin
import Foundation

/// HOME overrides do not isolate CFPreferences from the current cfprefsd user.
enum NativeSmokeIsolation {
    static let blockedMessage = "Native Transcripted smoke blocked: this macOS account may share the owner's UserDefaults and TCC state. Run in a separate OS account or a verified hosted CI runner. HOME overrides do not isolate preferences."

    static func allowed(
        uid: uid_t,
        euid: uid_t,
        consoleUID: uid_t?,
        ci: Bool,
        githubActions: Bool,
        githubHosted: Bool,
        virtualMachine: Bool,
        hostedRunnerAccount: Bool
    ) -> Bool {
        guard uid != 0, euid == uid, let consoleUID else { return false }
        if ci && githubActions && githubHosted && (virtualMachine || hostedRunnerAccount) { return true }
        return consoleUID != 0 && uid != consoleUID
    }

    static func isAllowed() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: "/dev/console"),
              let consoleUID = attributes[.ownerAccountID] as? NSNumber else { return false }
        var virtualMachine: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let hasVM = sysctlbyname("kern.hv_vmm_present", &virtualMachine, &size, nil, 0) == 0
            && virtualMachine == 1
        let environment = ProcessInfo.processInfo.environment
        let account = getpwuid(getuid())
        let hostedRunnerAccount = account.map {
            String(cString: $0.pointee.pw_name) == "runner"
                && String(cString: $0.pointee.pw_dir) == "/Users/runner"
        } ?? false
        return allowed(
            uid: getuid(),
            euid: geteuid(),
            consoleUID: consoleUID.uint32Value,
            ci: environment["CI"] == "true",
            githubActions: environment["GITHUB_ACTIONS"] == "true",
            githubHosted: environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            virtualMachine: hasVM,
            hostedRunnerAccount: hostedRunnerAccount
        )
    }
}
