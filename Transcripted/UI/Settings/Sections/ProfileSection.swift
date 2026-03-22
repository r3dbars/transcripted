import SwiftUI

@available(macOS 26.0, *)
struct ProfileSettingsSection: View {

    @Binding var userName: String
    @Binding var saveLocation: String
    var chooseSaveFolder: () -> Void

    var body: some View {
        SettingsSectionCard(icon: "person.fill", title: "Profile") {
            VStack(spacing: Spacing.md) {
                SettingsTextField(
                    title: "Your Name",
                    placeholder: "Enter your name",
                    text: $userName
                )

                Divider().background(Color.panelCharcoalSurface)

                SettingsPathRow(
                    title: "Save Location",
                    path: saveLocation,
                    defaultPath: "~/Documents/Transcripted/",
                    onChoose: chooseSaveFolder
                )
            }
        }
    }
}
