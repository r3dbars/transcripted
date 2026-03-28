import ArgumentParser
import Foundation

struct CheckHealth: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-health",
        abstract: "Check overall system health (directories, models, disk space, macOS version)."
    )

    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let results = HealthChecker().validate()
        runValidation(results: results, format: formatOpts.format)
    }
}
