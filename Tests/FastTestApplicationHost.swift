import AppKit

/// Native fixtures post AppKit events. Those events stop the current CFRunLoop
/// to wake AppKit's outer event loop; Swift's command-line async-main drain
/// can instead treat that return as process completion, even with tests pending.
/// Keep process lifetime with AppKit and exit only after the test body returns.
enum FastTestApplicationHost {
    @MainActor
    static func run(_ tests: @escaping @MainActor () async -> Void) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            await tests()
            exit(0)
        }
        application.run()
        fputs("Fast-test AppKit host returned before the tests completed.\n", stderr)
        exit(1)
    }
}
