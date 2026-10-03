// NotchIslandController+DictationDrop.swift
// What keeps the dictation hover cheap: the drop-down stays built while the
// take is spoken (NotchIslandView keeps it between hovers) and the target
// app's icon is drawn once per take. Visuals and the 120 ms open delay are
// unchanged; only the rebuilding is gone.

import AppKit

extension NotchIslandController {
    /// The "Insert into <app>" icon at the button's size, drawn the first
    /// time a drop-down asks for it during a take and reused after.
    func targetAppIcon() -> NSImage? {
        let colorSpace = islandView?.window?.colorSpace ?? NSScreen.main?.colorSpace ?? .sRGB
        return targetAppIconCache.icon(for: targetApp) { [targetApp] in
            targetApp?.icon.map {
                NotchIslandAppIconCache.bitmap(of: $0, side: NotchIslandButton.appIconSide(), colorSpace: colorSpace)
            }
        }
    }

    /// The kept drop-down belongs to the take being spoken; once the take
    /// is written, ends or is cancelled, it goes.
    func releaseKeptDictationDropIfTakeEnded() {
        switch dictation?.phase {
        case .starting?, .listening?:
            return
        default:
            islandView?.releaseKeptDictationDrop()
        }
    }
}
