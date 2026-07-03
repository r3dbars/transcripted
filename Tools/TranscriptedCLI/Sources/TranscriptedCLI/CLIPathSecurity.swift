import Foundation
import TranscriptedCaptureKit

// Path validation is shared with TranscriptedMCP through TranscriptedCaptureKit
// so the traversal / symlink guards live in exactly one place. These aliases
// keep the existing `CLIPathSecurity` / `CLIPathResolutionStatus` call sites in
// this module unchanged. Edit the rules in
// `TranscriptedCaptureKit/CapturePathSecurity.swift`, not here.
typealias CLIPathResolutionStatus = CapturePathResolutionStatus
typealias CLIPathSecurity = CapturePathSecurity
