// HomeCaptureRefreshObserver.swift
// Bridges `.meetingCaptureArtifactsDidChange` into a plain callback so Home's
// scan-time cache can re-resolve its transcript/audio URLs after background
// recompression or transcript rename mutates the files underneath it.
//
// Kept free of SwiftUI so the wiring is unit-testable: the owner (HomeViewModel)
// supplies an `onChange` closure that triggers a silent reload. The broadcaster
// already debounces, so this observer simply forwards each coalesced signal
// together with the affected transcript identifiers (empty == library-wide).

import Foundation

final class HomeCaptureRefreshObserver {
    private let notificationCenter: NotificationCenter
    private let onChange: @Sendable ([String]) -> Void
    private var token: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.onChange = onChange
        // `queue: nil` delivers synchronously on the poster's thread. The
        // broadcaster posts from the main actor, so the callback runs on main;
        // the callback itself is responsible for any actor hop it needs.
        token = notificationCenter.addObserver(
            forName: .meetingCaptureArtifactsDidChange,
            object: nil,
            queue: nil
        ) { [onChange] note in
            let ids = note.userInfo?[CaptureLibraryChange.affectedTranscriptIDsKey] as? [String] ?? []
            onChange(ids)
        }
    }

    deinit {
        if let token {
            notificationCenter.removeObserver(token)
        }
    }
}
