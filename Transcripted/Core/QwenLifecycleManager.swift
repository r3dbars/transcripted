import Foundation

// MARK: - Qwen Model Lifecycle (Pre-load, Timeout, Memory)

@available(macOS 26.0, *)
extension TranscriptionTaskManager {

    /// Pre-load Qwen model when recording starts so it's ready by the time the pipeline needs it.
    /// Only pre-loads if enabled AND model already cached (don't trigger a download during recording).
    func prepareForRecording() {
        guard QwenService.isEnabled, QwenService.isModelCached else { return }

        // Check available memory — Qwen needs ~2.5GB, require 4GB headroom
        guard hasMemoryForQwen() else {
            AppLogger.pipeline.info("Skipping Qwen pre-load — low memory")
            return
        }

        // Don't create a second instance if already loading/ready
        if let existing = qwenService {
            if case .ready = existing.modelState { return }
            if case .loading = existing.modelState { return }
        }

        AppLogger.pipeline.info("Pre-loading Qwen model for recording")

        qwenTimeoutTask?.cancel()
        let qwen = QwenService()
        self.qwenService = qwen

        qwenPreloadTask = Task { @MainActor [weak self] in
            await qwen.loadModel()
            if case .ready = qwen.modelState {
                AppLogger.pipeline.info("Qwen model pre-loaded and ready")
            } else {
                self?.qwenService = nil
            }
        }

        // Don't start the timeout yet — it will be started after the pipeline finishes
        // or if the recording is cancelled. This prevents Qwen from unloading during
        // long recordings (the old 5-minute timeout would fire mid-recording).
    }

    /// Start the Qwen safety timeout. Call this after the transcription pipeline finishes
    /// (or if the recording is cancelled) to free memory if Qwen wasn't consumed.
    func startQwenTimeout() {
        qwenTimeoutTask?.cancel()
        qwenTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            if let self, self.qwenService != nil {
                AppLogger.pipeline.info("Qwen timeout — unloading unused model")
                self.cleanupQwen()
            }
        }
    }

    /// Check if enough memory is available for Qwen (~2.5GB model, require 2GB headroom).
    /// Returns true if memory is sufficient or the check is unavailable.
    nonisolated func hasMemoryForQwen() -> Bool {
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return true }  // if check fails, allow the attempt
        let pageSize = UInt64(vm_kernel_page_size)
        let freeBytes = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
        let requiredBytes: UInt64 = 2 * 1024 * 1024 * 1024
        AppLogger.pipeline.debug("Qwen memory check", [
            "freeGB": String(format: "%.1f", Double(freeBytes) / 1_073_741_824),
            "requiredGB": "2.0",
            "sufficient": freeBytes >= requiredBytes ? "yes" : "no"
        ])
        return freeBytes >= requiredBytes
    }

    func cleanupQwen() {
        qwenTimeoutTask?.cancel()
        qwenTimeoutTask = nil
        qwenPreloadTask = nil
        qwenService?.unload()
        qwenService = nil
    }
}
