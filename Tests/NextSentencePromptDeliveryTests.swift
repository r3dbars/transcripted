import Foundation

@MainActor
func testNextSentencePromptDelivery() async {
    await runSuite("Prompt delivery writes off main while preserving the text and optional image envelope") {
        for image in [nil, Data(), Data([0, 1, 2, 255])] as [Data?] {
            let deadline = PromptDeliveryFixtureDeadline()
            let prompt = "Synthetic reply 🐟"
            let record: PromptDeliveryFixtureRecord? = await withCheckedContinuation { continuation in
                NextSentencePromptDelivery.send(
                    prompt: prompt, image: image, timeout: 60,
                    write: { object in
                        let data = try JSONSerialization.data(withJSONObject: object)
                        continuation.resume(returning: PromptDeliveryFixtureRecord(
                            data: data, onMain: Thread.isMainThread,
                            deadlineWasArmed: deadline.hasAction
                        ))
                    },
                    onFailure: { continuation.resume(returning: nil) },
                    scheduleTimeout: { delay, action in deadline.arm(delay: delay, action: action) }
                )
            }
            assertTrue(record != nil, "synthetic prompt delivery should succeed")
            guard let record,
                  let object = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                assertTrue(false, "delivery must produce the user-message envelope")
                continue
            }
            assertFalse(record.onMain, "a slow stdin write must not run on the main thread")
            assertTrue(record.deadlineWasArmed, "the deadline must already exist when writing starts")
            assertEqual(deadline.delay, 60)
            assertEqual(object["type"] as? String, "user")
            assertEqual(message["role"] as? String, "user")
            assertEqual(content.count, image == nil ? 1 : 2)
            assertEqual(content.last?["type"] as? String, "text")
            assertEqual(content.last?["text"] as? String, prompt)
            if let image {
                let source = content.first?["source"] as? [String: Any]
                assertEqual(content.first?["type"] as? String, "image")
                assertEqual(source?["type"] as? String, "base64")
                assertEqual(source?["media_type"] as? String, "image/jpeg")
                assertEqual(source?["data"] as? String, image.base64EncodedString())
            }
        }
    }

    await runSuite("A failed prompt write reports failure once even if its deadline later fires") {
        let deadline = PromptDeliveryFixtureDeadline()
        let failures = PromptDeliveryFixtureCounter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NextSentencePromptDelivery.send(
                prompt: "Synthetic failure", image: nil, timeout: 90,
                write: { _ in throw PromptDeliveryFixtureError.writeFailed },
                onFailure: { if failures.increment() == 1 { continuation.resume() } },
                scheduleTimeout: { delay, action in deadline.arm(delay: delay, action: action) }
            )
        }
        assertEqual(failures.value, 1)
        deadline.fire()
        deadline.fire()
        assertEqual(failures.value, 1, "write and timeout failures share one terminal notification")
    }

    runSuite("A prompt whose deadline expires before its worker starts is never written") {
        let deadline = PromptDeliveryFixtureDeadline()
        let queued = PromptDeliveryFixtureJob()
        let failures = PromptDeliveryFixtureCounter()
        let writes = PromptDeliveryFixtureCounter()
        NextSentencePromptDelivery.send(
            prompt: "Synthetic queued prompt", image: Data([1, 2]), timeout: 60,
            write: { _ in _ = writes.increment() },
            onFailure: { _ = failures.increment() },
            scheduleTimeout: { delay, action in deadline.arm(delay: delay, action: action) },
            background: { queued.store($0) }
        )
        assertTrue(deadline.hasAction, "queue congestion must not delay arming the deadline")
        assertTrue(queued.hasAction)
        assertEqual(writes.value, 0)
        deadline.fire()
        assertEqual(failures.value, 1)
        queued.run()
        assertEqual(writes.value, 0, "an expired queued request must not reach stdin")
        deadline.fire()
        assertEqual(failures.value, 1)
    }

    runSuite("An immediate write failure releases its callback captures before the deadline") {
        let deadline = PromptDeliveryFixtureDeadline()
        let queued = PromptDeliveryFixtureJob()
        let failures = PromptDeliveryFixtureCounter()
        let reference = PromptDeliveryFixtureWeakReference()
        armPromptDeliveryFailureCapture(reference, deadline: deadline, queued: queued, failures: failures)
        assertNotNil(reference.value, "the pending failure callback owns its synthetic capture")
        queued.run()
        assertEqual(failures.value, 1)
        assertNil(reference.value, "a reported write failure must release request captures")
        assertTrue(deadline.hasAction, "the manual deadline is still retained during this check")
        deadline.fire()
        deadline.fire()
        assertEqual(failures.value, 1)
    }
}

@MainActor
private func armPromptDeliveryFailureCapture(
    _ reference: PromptDeliveryFixtureWeakReference,
    deadline: PromptDeliveryFixtureDeadline,
    queued: PromptDeliveryFixtureJob,
    failures: PromptDeliveryFixtureCounter
) {
    let capture = PromptDeliveryFixtureCapture(failures)
    reference.value = capture
    NextSentencePromptDelivery.send(
        prompt: "Synthetic lifetime", image: nil, timeout: 60,
        write: { _ in throw PromptDeliveryFixtureError.writeFailed },
        onFailure: { capture.noteFailure() },
        scheduleTimeout: { delay, action in deadline.arm(delay: delay, action: action) },
        background: { queued.store($0) }
    )
}

private final class PromptDeliveryFixtureCapture: Sendable {
    let failures: PromptDeliveryFixtureCounter
    init(_ failures: PromptDeliveryFixtureCounter) { self.failures = failures }
    func noteFailure() { _ = failures.increment() }
}

@MainActor
private final class PromptDeliveryFixtureWeakReference {
    weak var value: PromptDeliveryFixtureCapture?
}

private struct PromptDeliveryFixtureRecord: Sendable {
    let data: Data
    let onMain: Bool
    let deadlineWasArmed: Bool
}

private enum PromptDeliveryFixtureError: Error { case writeFailed }

private final class PromptDeliveryFixtureDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var storedDelay: TimeInterval?
    var hasAction: Bool { lock.withLock { action != nil } }
    var delay: TimeInterval? { lock.withLock { storedDelay } }
    func arm(delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        lock.withLock { self.action = action; storedDelay = delay }
    }
    func fire() { lock.withLock { action }?() }
}

private final class PromptDeliveryFixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class PromptDeliveryFixtureJob: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    var hasAction: Bool { lock.withLock { action != nil } }
    func store(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
    func run() { lock.withLock { action }?() }
}
