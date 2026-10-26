import ArgumentParser
import Foundation

struct GenerateFixtures: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-fixtures",
        abstract: "Generate valid test data that passes all validators."
    )

    @Option(name: .long, help: "Output directory for generated test data")
    var output: String = "/tmp/transcripted-test-data"

    static let markerName = ".transcripted-qa-fixtures"

    func run() throws {
        let outputURL = URL(fileURLWithPath: output)
        let fm = FileManager.default
        let marker = outputURL.appendingPathComponent(Self.markerName)

        // Clean previous run, but only a folder this command made (or an empty one).
        if fm.fileExists(atPath: output) {
            let contents = try fm.contentsOfDirectory(atPath: output)
            guard contents.isEmpty || fm.fileExists(atPath: marker.path) else {
                throw ValidationError("output exists and is not a generate-fixtures folder: \(output)")
            }
            try fm.removeItem(at: outputURL)
        }

        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data().write(to: marker)
        let generator = TestDataGenerator(outputDir: outputURL)
        try generator.generateAll()

        print("Generated test fixtures at: \(output)")

        // List what was created
        if let contents = try? fm.contentsOfDirectory(atPath: output) {
            for item in contents.sorted() {
                print("  \(item)")
            }
        }

        // List logs subdirectory
        let logsDir = outputURL.appendingPathComponent("Logs")
        if let logContents = try? fm.contentsOfDirectory(atPath: logsDir.path) {
            for item in logContents.sorted() {
                print("  Logs/\(item)")
            }
        }
    }
}
