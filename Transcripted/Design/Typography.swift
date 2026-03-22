import SwiftUI
import AppKit

// MARK: - Typography Scale

extension Font {
    // MARK: - Display Fonts (Fraunces serif)
    static let displayLarge: Font = {
        if let _ = NSFont(name: "Fraunces-Bold", size: 36) {
            return .custom("Fraunces-Bold", size: 36)
        }
        return .system(size: 36, weight: .bold, design: .serif)
    }()

    static let displayMedium: Font = {
        if let _ = NSFont(name: "Fraunces-SemiBold", size: 28) {
            return .custom("Fraunces-SemiBold", size: 28)
        }
        return .system(size: 28, weight: .semibold, design: .serif)
    }()

    static let displaySmall: Font = {
        if let _ = NSFont(name: "Fraunces-Medium", size: 22) {
            return .custom("Fraunces-Medium", size: 22)
        }
        return .system(size: 22, weight: .medium, design: .serif)
    }()

    // MARK: - Heading Fonts
    static let headingLarge = Font.system(size: 20, weight: .semibold)
    static let headingMedium = Font.system(size: 18, weight: .semibold)
    static let headingSmall = Font.system(size: 16, weight: .semibold)

    // MARK: - Body Fonts
    static let bodyLarge = Font.system(size: 16, weight: .regular)
    static let bodyMedium = Font.system(size: 14, weight: .regular)
    static let bodySmall = Font.system(size: 13, weight: .regular)

    // MARK: - UI Fonts
    static let buttonText = Font.system(size: 15, weight: .semibold)
    static let caption = Font.system(size: 12, weight: .medium)
    static let tiny = Font.system(size: 11, weight: .regular)
    static let transcript = Font.system(size: 14, weight: .regular, design: .monospaced)
}
