import Foundation

func testMeetingTitlesGuards() {
    runSuite("Titles lose quotes and trailing punctuation") {
        assertEqual(MeetingTitlesGuards.title("\"Vendor contract renewal.\""), "Vendor contract renewal")
        assertEqual(MeetingTitlesGuards.title("“Q3 pricing review”!"), "Q3 pricing review")
        assertEqual(MeetingTitlesGuards.title("Title: Hiring plan"), "Hiring plan")
    }

    runSuite("Titles keep at most six words") {
        assertEqual(
            MeetingTitlesGuards.title("Planning the new onboarding flow and the pricing page"),
            "Planning the new onboarding flow"
        )
    }

    runSuite("Empty, generic or prompt-echo titles are thrown away") {
        assertNil(MeetingTitlesGuards.title("   "))
        assertNil(MeetingTitlesGuards.title("Meeting"))
        assertNil(MeetingTitlesGuards.title("Weekly sync call"))
        assertNil(MeetingTitlesGuards.title("Summary"))
        assertNil(MeetingTitlesGuards.title("Reply with the JSON now"))
        assertNil(MeetingTitlesGuards.title("<transcript>"))
    }

    runSuite("The line keeps at most two sentences") {
        assertEqual(
            MeetingTitlesGuards.line("The launch moves to May. Design signs off first. QA starts after.", summaryFallback: nil),
            "The launch moves to May. Design signs off first."
        )
    }

    runSuite("The line stays under about 45 words, cut at a sentence boundary") {
        let long = Array(repeating: "word", count: 45).joined(separator: " ")
        let line = MeetingTitlesGuards.line("Budget is approved. Then \(long).", summaryFallback: nil)
        assertEqual(line, "Budget is approved.")
    }

    runSuite("Sentences that hand the recorder a task are dropped") {
        assertEqual(
            MeetingTitlesGuards.line("You will send the deck by Friday. The launch moves to May.", summaryFallback: nil),
            "The launch moves to May."
        )
        for sentence in ["You'll follow up with legal.", "You need to book the room.", "You are going to draft it.", "Next, you will call Dana."] {
            assertTrue(MeetingTitlesGuards.assignsTaskToRecorder(sentence), sentence)
        }
        assertFalse(MeetingTitlesGuards.assignsTaskToRecorder("Your team picked the current vendor."))
    }

    runSuite("With no clean line left, the summary's first clean sentence stands in") {
        let line = MeetingTitlesGuards.line(
            "You'll send the notes.",
            summaryFallback: "You need to call the vendor. The renewal goes ahead for a year. Support is the risk."
        )
        assertEqual(line, "The renewal goes ahead for a year.")
        assertNil(MeetingTitlesGuards.line("You'll send the notes.", summaryFallback: "You must call back."))
    }

    runSuite("The summary keeps at most three sentences and drops recorder tasks") {
        assertEqual(
            MeetingTitlesGuards.summary("One. Two is here. You will do three. Four now. Five."),
            "One. Two is here. Four now."
        )
        assertNil(MeetingTitlesGuards.summary("You'll handle it."))
    }

    runSuite("A reply that isn't the JSON object is unusable") {
        assertNil(MeetingTitlesGuards.label(fromModelReply: "Sure! Here is a title: Budget"))
        assertNil(MeetingTitlesGuards.label(fromModelReply: #"{"title": "Budget"}"#))
        assertNil(MeetingTitlesGuards.label(fromModelReply: ""))
    }

    runSuite("A good reply comes through with every field guarded") {
        let label = MeetingTitlesGuards.label(fromModelReply: #"<think></think>{"title": "Budget review.", "line": "The budget is approved. You will send it out. Spending starts in May.", "summary": "Finance went line by line. The budget is approved."}"#)
        assertEqual(label?.title, "Budget review")
        assertEqual(label?.line, "The budget is approved. Spending starts in May.")
        assertEqual(label?.summary, "Finance went line by line. The budget is approved.")
    }

    runSuite("The recorder-task rule catches shared tasks, lead-ins and next steps, and keeps 'you'll see' lines") {
        for sentence in [
            "You and Priya will review the contract.",
            "You and the team will ship it Friday.",
            "After the call, you will send the deck.",
            "Your next step is to call the vendor.",
        ] {
            assertTrue(MeetingTitlesGuards.assignsTaskToRecorder(sentence), sentence)
        }
        for sentence in ["You'll see the numbers in the doc.", "You will notice support tickets dropped.", "The team will ship it Friday."] {
            assertFalse(MeetingTitlesGuards.assignsTaskToRecorder(sentence), sentence)
        }
    }

    runSuite("Chinese and Japanese text splits on 。！？ and is capped by characters") {
        assertEqual(MeetingTitlesGuards.sentences(in: "決定しました。来週から移行します！本当？"), ["決定しました。", "来週から移行します！", "本当？"])
        let line = MeetingTitlesGuards.line("請求の切り替えを決めた。来週から移行する。税の確認で最終判断。", summaryFallback: nil)
        assertEqual(line, "請求の切り替えを決めた。来週から移行する。")
        let longSentence = String(repeating: "移", count: 120) + "。"
        assertNil(MeetingTitlesGuards.line(longSentence, summaryFallback: nil), "over the character cap")
        let title = MeetingTitlesGuards.title(String(repeating: "請求", count: 15))
        assertEqual(title?.count, MeetingTitlesGuards.maxUnspacedTitleCharacters)
    }

    runSuite("A title cut to six words loses a trailing connector") {
        for (raw, expected) in [
            ("Roadmap review for the next quarter planning", "Roadmap review for the next quarter"),
            ("Pricing page copy review and the launch email", "Pricing page copy review"),
            ("Hiring plan budget numbers review of candidates", "Hiring plan budget numbers review"),
        ] {
            assertEqual(MeetingTitlesGuards.title(raw), expected, raw)
        }
    }

    runSuite("Abbreviations don't split sentences") {
        assertEqual(MeetingTitlesGuards.sentences(in: "The U.S. team agreed. Then we left."), ["The U.S. team agreed.", "Then we left."])
        assertEqual(MeetingTitlesGuards.sentences(in: "Acme Inc. Renewed the deal. Done."), ["Acme Inc. Renewed the deal.", "Done."])
        assertEqual(MeetingTitlesGuards.sentences(in: "Finance said no. The budget stays."), ["Finance said no.", "The budget stays."])
        assertEqual(MeetingTitlesGuards.sentences(in: "Item No. 5 shipped. Then we left."), ["Item No. 5 shipped.", "Then we left."])
        assertEqual(MeetingTitlesGuards.sentences(in: "Dr. Lee agreed, e.g. on pricing. Then we left."), ["Dr. Lee agreed, e.g. on pricing.", "Then we left."])
    }
}
