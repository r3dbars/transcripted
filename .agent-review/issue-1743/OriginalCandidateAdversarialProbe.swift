import Foundation

@main struct AdversarialProbe {
    @MainActor static func main() async {
        var now = 0.0
        var current = true
        let originallyReadyMic = true
        let helper = DictationStartActivation()
        let admitted = await helper.prepare(
            isCurrent: { current }, isActive: { false }, activate: {}, restore: {},
            now: { now }, wait: {
                now += 0.1
                if now >= 0.1 { current = false; helper.cancel() }
            }
        )
        print("ready_mic_released_at_100ms: old_start=\(originallyReadyMic), patched_start=\(admitted), activation_wait_ms=\(Int(now*1000))")

        now = 0
        var front = "editor_A"
        _ = await DictationStartActivation().prepare(
            isCurrent: { true }, isActive: { front == "Transcripted" }, activate: {},
            restore: { front = "editor_A" }, now: { now }, wait: {
                now += 0.1
                front = now < 0.2 ? "editor_B" : "Transcripted"
            }
        )
        print("user_switch_before_activation: chosen=editor_B, restored=\(front)")

        now = 0
        front = "editor_A"
        let late = DictationStartActivation()
        _ = await late.prepare(
            isCurrent: { true }, isActive: { front == "Transcripted" }, activate: {},
            restore: { front = "editor_A" }, now: { now }, wait: { now += 0.1 }
        )
        front = "Transcripted" // pending OS request completes after the deadline
        print("activation_after_deadline: frontmost=\(front), cleanup_finished_at_ms=\(Int(now*1000))")
    }
}
