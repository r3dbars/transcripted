import SwiftUI

/// The Writing page (⌘4). A placeholder for now: the intro, setup, and
/// everyday views land here in Writing phase 4. When setup finishes, the page
/// sets `WritingSidebarNewBadge.dismissedDefaultsKey` so the sidebar drops its
/// "New" badge.
struct WritingSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Writing",
                summary: "Save what you write for your AI, and get autocomplete as you type. Everything stays on this Mac."
            )
        }
        .accessibilityIdentifier("transcripted.settings.page.writing")
    }
}
