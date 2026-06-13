import Foundation

func testHomeCanvasGreeting() {
    runSuite("HomeCanvasGreeting.text — time-of-day salutation with the first name") {
        assertEqual(HomeCanvasGreeting.text(hour: 8, firstName: "Redbars"), "Good morning, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 13, firstName: "Redbars"), "Good afternoon, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 20, firstName: "Redbars"), "Good evening, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 2, firstName: "Redbars"), "Good evening, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 5, firstName: "Redbars"), "Good morning, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 17, firstName: "Redbars"), "Good evening, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 9, firstName: "  "), "Good morning", "blank names should drop the comma")
    }
}
