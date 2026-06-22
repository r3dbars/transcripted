import Foundation

func testAccessibilityBridge() {
    runSuite("AccessibilityBridge focused text policy rejects secure fields") {
        assertFalse(
            AccessibilityBridge.acceptsFocusedTextRole("AXSecureTextField", subrole: nil),
            "secure text fields should never be exposed as paste/overlay targets"
        )
        assertFalse(
            AccessibilityBridge.acceptsFocusedTextRole("AXTextField", subrole: "AXSecureTextField"),
            "text fields with secure subroles should never be exposed as paste/overlay targets"
        )
    }

    runSuite("AccessibilityBridge focused text policy accepts normal text fields") {
        for role in ["AXTextArea", "AXTextField", "AXWebArea", "AXTextView", "AXComboBox", "CustomTextEditor"] {
            assertTrue(
                AccessibilityBridge.acceptsFocusedTextRole(role, subrole: nil),
                "\(role) should stay eligible for focused-editor metadata"
            )
        }
    }

    runSuite("AccessibilityBridge focused text policy rejects non-text controls") {
        for role in ["AXButton", "AXSlider", "AXImage", "AXGroup"] {
            assertFalse(
                AccessibilityBridge.acceptsFocusedTextRole(role, subrole: nil),
                "\(role) should not be treated as a focused editor"
            )
        }
    }
}
