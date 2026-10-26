import Foundation
import TranscriptedCaptureKit

// Path validation is shared with TranscriptedMCP through TranscriptedCaptureKit
// so the traversal / symlink guards live in exactly one place. This alias
// keeps the existing `CLIPathSecurity` call sites in this module unchanged. Edit the rules in
// `TranscriptedCaptureKit/CapturePathSecurity.swift`, not here.
typealias CLIPathSecurity = CapturePathSecurity
