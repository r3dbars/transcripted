import Foundation

struct ObservabilityEvent: Codable {
    let timestamp: String
    let level: String
    let engine: String
    let event: String
    let message: String
    let context: [String: String]?
    let appVersion: String
    let osVersion: String
}
