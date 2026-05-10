import Foundation

enum EventFileWritePolicy {
    static let bufferedLevel = "info"
    static let maxBufferedInfoEvents = 8
    static let infoFlushDelayNanoseconds: UInt64 = 500_000_000

    static func shouldBuffer(level: String) -> Bool {
        level == bufferedLevel
    }

    static func shouldFlushBufferedInfoEvents(count: Int) -> Bool {
        count >= maxBufferedInfoEvents
    }
}
