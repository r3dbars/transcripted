import AppKit

@MainActor
func testNotchIslandAppIconCache() {
    runSuite("The take's app icon is drawn once, not on every hover") {
        let cache = NotchIslandAppIconCache()
        let notes = NSObject()
        let slack = NSObject()
        var renders = 0
        func draw() -> NSImage? {
            renders += 1
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        let first = cache.icon(for: notes, render: draw)
        assertNotNil(first, "the first hover draws the icon")
        assertEqual(renders, 1, "drawn once")

        let second = cache.icon(for: notes, render: draw)
        assertEqual(renders, 1, "a second hover for the same app doesn't draw again")
        assertTrue(first != nil && first === second, "and gets the very same image back")

        for _ in 0..<5 { _ = cache.icon(for: notes, render: draw) }
        assertEqual(renders, 1, "many hovers, still one drawing")

        let other = cache.icon(for: slack, render: draw)
        assertEqual(renders, 2, "a take aimed at another app draws its icon")
        assertNotNil(other, "the other app gets an icon")
        assertFalse(other === first, "a different app's icon is not the first app's image")

        let again = cache.icon(for: slack, render: draw)
        assertEqual(renders, 2, "and that one is kept too")
        assertTrue(other != nil && again === other, "same image for the same app")
    }

    runSuite("No target app means no icon and no drawing") {
        let cache = NotchIslandAppIconCache()
        var renders = 0
        let icon = cache.icon(for: nil) {
            renders += 1
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        assertNil(icon, "a take with no target app has no icon")
        assertEqual(renders, 0, "and nothing is drawn")
    }

    runSuite("An icon that can't be drawn comes back as nothing") {
        let cache = NotchIslandAppIconCache()
        var renders = 0
        let icon = cache.icon(for: NSObject()) {
            renders += 1
            return nil
        }
        assertNil(icon, "a failed drawing gives no icon")
        assertEqual(renders, 1, "the drawing was tried")
    }
}
