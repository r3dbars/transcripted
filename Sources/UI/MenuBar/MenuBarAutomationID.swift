// MenuBarAutomationID.swift
// Stable accessibility identifiers for the status item and the popover's rows.
// External automation finds controls by these strings (Tools/TranscriptedQA
// UISmoke, the build.sh launch smoke, scripts/ops/packaged-app-smoke.py), so a
// raw value only changes in lockstep with those lists.

enum MenuBarAutomationID: String, CaseIterable {
    case statusItemButton = "transcripted.status-item.button"
    case startMeeting = "transcripted.menubar.primary.start-meeting"
    case startDictation = "transcripted.menubar.primary.start-dictation"
    case openTranscripted = "transcripted.menubar.utility.open-transcripted"
    case checkUpdates = "transcripted.menubar.utility.check-updates"
    case quit = "transcripted.menubar.utility.quit"
}
