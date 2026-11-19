import AppKit
import CoreText

/// The bundled typeface (SIL OFL 1.1, license in THIRD_PARTY_LICENSES.md):
/// JetBrains Mono for section labels. The TTFs ship in
/// `Contents/Resources/Fonts` and are registered for this process only, the
/// first time a role needs them.
/// Tests and smokes run without the bundle, so every caller has a system
/// fallback (`TextRole.nsFont` uses it).
enum BundledFonts {
    enum Face: String, CaseIterable, Sendable {
        case jetBrainsMonoRegular = "JetBrainsMono-Regular"
        case jetBrainsMonoMedium = "JetBrainsMono-Medium"

        /// PostScript name and file name are the same.
        var postScriptName: String { rawValue }
    }

    static let resourceSubdirectory = "Fonts"

    /// Registers the app bundle's fonts once, on first use of a bundled
    /// role (`TextRole.label`), so no launch hook is needed.
    nonisolated static let registerOnce: Void = {
        _ = registerForProcess()
    }()

    /// Registers every bundled face found in `bundle` for this process.
    /// Safe to call more than once; returns the faces now available.
    @discardableResult
    static func registerForProcess(bundle: Bundle = .main) -> [Face] {
        guard let directory = bundle.resourceURL?.appendingPathComponent(resourceSubdirectory, isDirectory: true) else {
            return Face.allCases.filter(isAvailable)
        }
        return register(directory: directory)
    }

    /// Registers the faces in `directory` (used by `registerForProcess` and
    /// by tests pointing at `Resources/Fonts`).
    @discardableResult
    static func register(directory: URL) -> [Face] {
        for face in Face.allCases where !isAvailable(face) {
            let url = directory.appendingPathComponent(face.rawValue).appendingPathExtension("ttf")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // An "already registered" error is fine; anything else leaves the
            // fallback in place.
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return Face.allCases.filter(isAvailable)
    }

    static func isAvailable(_ face: Face) -> Bool {
        NSFont(name: face.postScriptName, size: 12) != nil
    }

    /// The bundled face at `size`, or nil when it isn't registered.
    static func font(_ face: Face, size: CGFloat) -> NSFont? {
        NSFont(name: face.postScriptName, size: size)
    }
}
