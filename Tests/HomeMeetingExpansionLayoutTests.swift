// An opened Meetings card (QuietMeetingExpansion) keeps Copy at the top,
// where the closed row shows it, and a click on its header closes it again,
// like clicking the row opened it (HomeMeetingExpansionLayout).

import Foundation

func testHomeMeetingExpansionLayout() {
    runSuite("Opened meeting keeps Copy at the top") {
        assertEqual(
            HomeMeetingExpansionLayout.headerActions.first,
            .copy,
            "Copy leads the header actions, as on the closed row"
        )
        assertFalse(
            HomeMeetingExpansionLayout.footerActions.contains(.copy),
            "Copy doesn't move under the transcript"
        )
        assertTrue(
            HomeMeetingExpansionLayout.headerActions.contains(.star),
            "an opened meeting can be starred from its header"
        )
        assertEqual(
            Set(HomeMeetingExpansionLayout.headerActions + HomeMeetingExpansionLayout.footerActions).count,
            HomeMeetingExpansionAction.allCases.count,
            "every action shows once"
        )
        assertEqual(
            (HomeMeetingExpansionLayout.headerActions + HomeMeetingExpansionLayout.footerActions).count,
            HomeMeetingExpansionAction.allCases.count,
            "no action shows twice"
        )
    }

    runSuite("Clicking an opened meeting's header closes it") {
        assertEqual(HomeMeetingExpansionLayout.headerClick, .collapse)
        var collapses = 0
        HomeMeetingExpansionLayout.performHeaderClick { collapses += 1 }
        assertEqual(collapses, 1, "the header dispatches its existing collapse action once")
    }
}
