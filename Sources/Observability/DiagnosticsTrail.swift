import Foundation

@MainActor
enum DiagnosticsTrail {
    static func record(
        logger: AppLogger? = nil,
        level: EventLevel = .info,
        engine: String,
        event: String,
        message: String,
        context: [String: String] = [:]
    ) {
        let trimmedContext = context.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if let logger {
            let detail = AnalyticsPayloadSanitizer.sanitizeDiagnosticContextForDisplay(trimmedContext)
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            if detail.isEmpty {
                logger.log("DIAG | \(engine).\(event) | \(message)")
            } else {
                logger.log("DIAG | \(engine).\(event) | \(message) | \(detail)")
            }
        }

        EventReporter.shared.capture(
            level: level,
            engine: engine,
            event: event,
            message: message,
            context: trimmedContext.isEmpty ? nil : trimmedContext
        )
    }
}
