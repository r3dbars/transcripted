#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Cocoa
import InputMethodKit

// The connection name MUST match `InputMethodConnectionName` in Info.plist.
let profile = TildeProductProfile.current
let connectionName = profile.inputMethodConnectionName
let bundleIdentifier = Bundle.main.bundleIdentifier ?? profile.inputMethodBundleIdentifier

// Retain the server for the process lifetime; IMK dispatches client sessions to it.
let server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
_ = server

NSApplication.shared.run()
