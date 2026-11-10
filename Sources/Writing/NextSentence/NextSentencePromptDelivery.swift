import Foundation

/// Encodes and writes a prompt away from the caller's thread. A congested
/// writer must not delay the request's deadline or send an already expired job.
enum NextSentencePromptDelivery {
    typealias TimeoutScheduler = (TimeInterval, @escaping @Sendable () -> Void) -> Void
    typealias Background = (@escaping @Sendable () -> Void) -> Void

    static func send(
        prompt: String,
        image: Data?,
        timeout: TimeInterval,
        write: @escaping ([String: Any]) throws -> Void,
        onFailure: @escaping () -> Void,
        scheduleTimeout: TimeoutScheduler = { delay, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: action)
        },
        background: Background = { action in
            DispatchQueue.global(qos: .userInitiated).async(execute: action)
        }
    ) {
        let failure = Failure(onFailure)
        // Only the terminal callback is retained by the deadline, not the image.
        scheduleTimeout(timeout) { failure.report() }
        let work = Work(prompt: prompt, image: image, write: write, failure: failure)
        background { work.perform() }
    }

    /// The write callback belongs to one worker; failure notification is locked
    /// because its deadline and write error can arrive on different queues.
    private final class Work: @unchecked Sendable {
        let prompt: String
        let image: Data?
        let write: ([String: Any]) throws -> Void
        let failure: Failure

        init(prompt: String, image: Data?, write: @escaping ([String: Any]) throws -> Void, failure: Failure) {
            self.prompt = prompt
            self.image = image
            self.write = write
            self.failure = failure
        }

        func perform() {
            guard !failure.hasFailed else { return }
            var content: [[String: Any]] = []
            if let image {
                content.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()],
                ])
            }
            content.append(["type": "text", "text": prompt])
            guard !failure.hasFailed else { return }
            do {
                try write(["type": "user", "message": ["role": "user", "content": content]])
            } catch {
                failure.report()
            }
        }
    }

    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var reported = false
        private var callback: (() -> Void)?

        init(_ callback: @escaping () -> Void) { self.callback = callback }
        var hasFailed: Bool { lock.withLock { reported } }

        func report() {
            let action: (() -> Void)? = lock.withLock {
                guard !reported else { return nil }
                reported = true
                // The deadline may keep this box alive after a write error.
                // Release the failed request's captures before leaving it there.
                defer { callback = nil }
                return callback
            }
            action?()
        }
    }
}
