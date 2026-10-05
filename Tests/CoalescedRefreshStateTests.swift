import Foundation

func testCoalescedRefreshState() {
    runSuite("Refresh bursts keep one running read and one final read") {
        var state = CoalescedRefreshState()
        assertTrue(state.request(), "the first request starts a read")
        for _ in 0..<100 {
            assertFalse(state.request(), "a notification cannot overlap the running read")
        }
        assertTrue(state.finished(), "the latest save still gets one trailing read")
        assertFalse(state.finished(), "one burst does not schedule a read per notification")
        assertFalse(state.isRunning, "the owner returns to idle")
    }

    runSuite("Hidden saves remain pending and reconcile once on reveal") {
        var state = CoalescedRefreshState(isEnabled: false)
        for _ in 0..<100 { assertFalse(state.request(), "hidden pages never start file reads") }
        assertTrue(state.isPending, "the last save has not been forgotten")
        state.isEnabled = true
        assertTrue(state.request(), "reveal consumes all hidden changes with one current read")
        assertFalse(state.finished(), "the hidden burst does not leak extra work after reveal")
    }

    runSuite("Closing during a read holds its pending change until reopen") {
        var state = CoalescedRefreshState()
        assertTrue(state.request())
        assertFalse(state.request(), "save during a read")
        state.isEnabled = false
        assertFalse(state.finished(), "completion cannot start a hidden trailing read")
        assertTrue(state.isPending, "closing did not drop the save")
        state.isEnabled = true
        assertTrue(state.request(), "reopen reads after the pending save")
        assertFalse(state.finished())
    }

    runSuite("Delayed edit and refresh completions cannot roll back a newer speaker snapshot") {
        var order = RefreshPublicationOrder()
        let beforeEdit = order.beginRead()
        let edit = order.beginRead()
        let afterEdit = order.beginRead()
        assertTrue(order.accept(afterEdit), "the newest completed read may publish first")
        assertFalse(order.accept(beforeEdit), "an older refresh cannot overwrite it")
        assertFalse(order.accept(edit), "a delayed edit continuation cannot overwrite it either")
        assertFalse(order.accept(afterEdit), "the same completion cannot publish twice")
        let laterEdit = order.beginRead()
        assertTrue(order.accept(laterEdit), "a subsequent edit still publishes normally")
    }

}
