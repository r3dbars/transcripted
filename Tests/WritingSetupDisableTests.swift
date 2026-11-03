import Foundation

@MainActor
func testWritingSetupDisable() {
    runSuite("Turning Writing off persists both features before applying its run state") {
        for save in [false, true] {
            for autocomplete in [false, true] {
                let controls = SetupFeatureControls(save: save, autocomplete: autocomplete)

                WritingSetupPresentation.turnOffWriting(using: controls)

                assertFalse(controls.saveMyWritingEnabled, "Save my writing is off")
                assertFalse(controls.autocomplete, "Autocomplete is off")
                assertFalse(controls.running, "the real default activation policy stops the runtime")
                assertEqual(controls.runStateApplications, 1, "one application after both settings are saved")
                assertEqual(controls.calls, save ? ["save:false", "autocomplete:false", "apply"]
                                               : ["autocomplete:false", "apply"],
                            "an already-off Save setting does not rotate consent again")
            }
        }
    }

    runSuite("Turning Writing off remains reversible") {
        let controls = SetupFeatureControls(save: true, autocomplete: true)
        WritingSetupPresentation.turnOffWriting(using: controls)
        assertFalse(controls.running)

        controls.setAutocomplete(true)
        controls.applyRunState()

        assertTrue(controls.running, "a later feature change can start Writing again")
        assertFalse(controls.saveMyWritingEnabled, "re-enabling Autocomplete keeps Save my writing off")
    }
}

@MainActor
private final class SetupFeatureControls: WritingSetupFeatureControl {
    var saveMyWritingEnabled: Bool
    var autocomplete: Bool
    var running: Bool
    var calls: [String] = []
    var runStateApplications = 0

    init(save: Bool, autocomplete: Bool) {
        saveMyWritingEnabled = save
        self.autocomplete = autocomplete
        running = WritingActivation.shouldRun(setupCompleted: true, saveMyWriting: save,
                                              autocomplete: autocomplete, debugEnabled: false)
    }

    func setSaveMyWriting(_ enabled: Bool) {
        calls.append("save:\(enabled)")
        saveMyWritingEnabled = enabled
    }

    func setAutocomplete(_ enabled: Bool) {
        calls.append("autocomplete:\(enabled)")
        autocomplete = enabled
    }

    func applyRunState() {
        calls.append("apply")
        runStateApplications += 1
        running = WritingActivation.shouldRun(setupCompleted: true, saveMyWriting: saveMyWritingEnabled,
                                              autocomplete: autocomplete, debugEnabled: false)
    }
}
