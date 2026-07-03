import Foundation
import TranscriptedCaptureKit

// Path validation is shared with TranscriptedCLI through TranscriptedCaptureKit
// so the traversal / symlink guards live in exactly one place. These aliases
// keep the existing `PathSecurity` / `PathResolutionStatus` call sites in this
// module unchanged. Edit the rules in
// `TranscriptedCaptureKit/CapturePathSecurity.swift`, not here.
typealias PathResolutionStatus = CapturePathResolutionStatus
typealias PathSecurity = CapturePathSecurity
