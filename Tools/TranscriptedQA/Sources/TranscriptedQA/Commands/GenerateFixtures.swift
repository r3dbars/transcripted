import ArgumentParser
import Foundation

struct GenerateFixtures: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-fixtures",
        abstract: "Generate valid test data that passes all validators."
    )

    @Option(name: .long, help: "Output directory for generated test data")
    var output: String = "/tmp/transcripted-test-data"

    func run() throws {
        let outputURL = URL(fileURLWithPath: output)
        let fm = FileManager.default

        // Clean previous run
        if fm.fileExists(atPath: output) {
            try fm.removeItem(at: outputURL)
        }

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
