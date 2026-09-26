import SwiftUI

/// The Writing page (⌘4). Until setup is done it shows the two intro pages,
/// then the three setup steps; after "Turn on writing" it shows the everyday
/// view (docs/writing-plan.md, "Product design (approved)"). The views live
/// in `Sources/UI/Settings/Writing/`; state and every runtime action go
/// through `WritingSettingsModel` and `WritingController`. "Turn on writing"
/// sets `WritingSidebarNewBadge.dismissedDefaultsKey`, which drops the
/// sidebar's "New" badge.
struct WritingSettingsPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var model: WritingSettingsModel
    /// A meeting or dictation is recording (or meeting audio is still being
    /// transcribed). The Screen Recording request waits while it's true.
    private let isCaptureBusy: () -> Bool

    init(controller: WritingController, isCaptureBusy: @escaping () -> Bool) {
        model = WritingSettingsModel.shared(for: controller)
        self.isCaptureBusy = isCaptureBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch model.screen {
            case let .intro(page):
                WritingIntroView(
                    page: page,
                    onNext: { model.showIntroPage(page + 1) },
                    onBack: { model.showIntroPage(page - 1) },
                    onSetUp: { model.beginSetup() },
                    onNotNow: { model.dismissNewBadge() }
                )
            case let .setup(step):
                WritingSetupFlowView(model: model, step: step)
            case .everyday:
                WritingEverydayView(model: model)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.screen)
        .background(WritingWindowReader { [model] window in model.hostWindow = window })
        .onAppear {
            model.isCaptureBusy = isCaptureBusy
            model.pageAppeared()
        }
        .onDisappear {
            model.pageDisappeared()
        }
        .accessibilityIdentifier("transcripted.settings.page.writing")
    }
}
