import Foundation

func testWritingAnalytics() {
    var chicago = Calendar(identifier: .gregorian)
    chicago.timeZone = TimeZone(identifier: "America/Chicago")!

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        chicago.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    func withScratchDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "WritingAnalyticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    let gemmaAll = WritingAnalytics.Setup(
        saveEnabled: true,
        autocompleteEnabled: true,
        appScope: .all,
        model: .gemma4E2B
    )

    runSuite("WritingAnalytics reports the whole local day before today") {
        let midnight = WritingAnalytics.previousDay(before: date(2026, 9, 25), calendar: chicago)
        assertEqual(midnight?.start, date(2026, 9, 24), "at midnight, yesterday starts at the previous midnight")
        assertEqual(midnight?.end, date(2026, 9, 25), "and ends at today's midnight")

        let lastSecond = WritingAnalytics.previousDay(before: date(2026, 9, 24, 23, 59, 59), calendar: chicago)
        assertEqual(lastSecond?.start, date(2026, 9, 23), "one second before midnight, yesterday is still the day before")
        assertEqual(lastSecond?.end, date(2026, 9, 24), "and today is not complete, so it is not reported")

        let springForward = WritingAnalytics.previousDay(before: date(2026, 3, 9, 8), calendar: chicago)
        assertEqual(springForward?.duration, TimeInterval(23 * 3600), "the spring-forward day is 23 hours")
        let fallBack = WritingAnalytics.previousDay(before: date(2026, 11, 2, 8), calendar: chicago)
        assertEqual(fallBack?.duration, TimeInterval(25 * 3600), "the fall-back day is 25 hours")

        assertEqual(WritingAnalytics.dayKey(for: date(2026, 3, 8), calendar: chicago), "2026-03-08", "day keys are zero-padded")
        assertEqual(WritingAnalytics.dayKey(for: date(2026, 12, 31, 23, 59), calendar: chicago), "2026-12-31", "day keys use the calendar's time zone")
    }

    runSuite("WritingAnalytics claims each day once") {
        withScratchDefaults { defaults in
            let first = WritingAnalytics.claimPreviousDay(now: date(2026, 9, 25, 9), calendar: chicago, defaults: defaults)
            assertEqual(first?.start, date(2026, 9, 24), "the first launch claims yesterday")
            assertEqual(
                defaults.string(forKey: WritingAnalytics.dailyCountsLastDayKey),
                "2026-09-24",
                "the claimed day is remembered in the given suite"
            )

            assertNil(
                WritingAnalytics.claimPreviousDay(now: date(2026, 9, 25, 9, 1), calendar: chicago, defaults: defaults),
                "a wake later the same day does not re-emit"
            )
            assertNil(
                WritingAnalytics.claimPreviousDay(now: date(2026, 9, 25, 23, 59, 59), calendar: chicago, defaults: defaults),
                "nor does one just before midnight"
            )

            let nextDay = WritingAnalytics.claimPreviousDay(now: date(2026, 9, 26, 0, 0, 1), calendar: chicago, defaults: defaults)
            assertEqual(nextDay?.start, date(2026, 9, 25), "just after midnight, the day that just ended is due")

            assertNil(
                WritingAnalytics.claimPreviousDay(now: date(2026, 9, 20, 12), calendar: chicago, defaults: defaults),
                "a clock moved back never re-reports an earlier day"
            )
            assertEqual(
                defaults.string(forKey: WritingAnalytics.dailyCountsLastDayKey),
                "2026-09-25",
                "and leaves the remembered day alone"
            )

            let afterGap = WritingAnalytics.claimPreviousDay(now: date(2026, 10, 3, 10), calendar: chicago, defaults: defaults)
            assertEqual(afterGap?.start, date(2026, 10, 2), "after days off, only the previous day is reported")
        }
    }

    runSuite("WritingAnalytics skips a day with nothing shown or accepted") {
        assertNil(
            WritingAnalytics.dailyCountsProperties(
                .init(suggestionsShown: 0, suggestionsAccepted: 0, acceptedCharacters: 0),
                setup: gemmaAll
            ),
            "an idle day sends nothing"
        )
        assertNil(
            WritingAnalytics.dailyCountsProperties(
                .init(suggestionsShown: -3, suggestionsAccepted: -1, acceptedCharacters: 40),
                setup: gemmaAll
            ),
            "negative counts clamp to zero and still count as idle"
        )
        assertNotNil(
            WritingAnalytics.dailyCountsProperties(
                .init(suggestionsShown: 4, suggestionsAccepted: 0, acceptedCharacters: 0),
                setup: gemmaAll
            ),
            "shown but never accepted is still a day worth reporting"
        )
    }

    runSuite("WritingAnalytics daily counts carry exactly the reviewed keys") {
        let properties = WritingAnalytics.dailyCountsProperties(
            .init(suggestionsShown: 42, suggestionsAccepted: 17, acceptedCharacters: 250),
            setup: gemmaAll
        )
        assertEqual(
            properties,
            [
                "suggestions_shown": "42",
                "suggestions_accepted": "17",
                "words_accepted_bucket": "50_149",
                "model_choice": "gemma_e2b",
                "save_enabled": "true",
                "autocomplete_enabled": "true",
                "app_scope": "all",
            ],
            "counts, a words bucket and the setup enums, nothing else"
        )

        let setup = WritingAnalytics.setupProperties(
            .init(saveEnabled: false, autocompleteEnabled: true, appScope: .picked, model: .qwen35B9B)
        )
        assertEqual(
            setup,
            [
                "save_enabled": "false",
                "autocomplete_enabled": "true",
                "app_scope": "picked",
                "model_choice": "qwen_9b",
            ],
            "setup completion carries the four setup choices only"
        )
    }

    runSuite("WritingAnalytics buckets accepted words on the word_count_bucket boundaries") {
        assertEqual(WritingAnalytics.wordsAccepted(fromCharacters: 0), 0, "no characters, no words")
        assertEqual(WritingAnalytics.wordsAccepted(fromCharacters: 2), 0, "rounds down below half a word")
        assertEqual(WritingAnalytics.wordsAccepted(fromCharacters: 3), 1, "rounds up from half a word")
        assertEqual(WritingAnalytics.wordsAccepted(fromCharacters: 50), 10, "five characters per standard word")
        assertEqual(WritingAnalytics.wordsAccepted(fromCharacters: -9), 0, "negative clamps to zero")

        func bucket(_ characters: Int) -> String? {
            WritingAnalytics.dailyCountsProperties(
                .init(suggestionsShown: 1, suggestionsAccepted: 1, acceptedCharacters: characters),
                setup: gemmaAll
            )?["words_accepted_bucket"]
        }
        assertEqual(bucket(44), "lt_10", "under 10 words")
        assertEqual(bucket(48), "10_49", "10 words")
        assertEqual(bucket(247), "10_49", "49 words")
        assertEqual(bucket(248), "50_149", "50 words")
        assertEqual(bucket(748), "150_299", "150 words")
        assertEqual(bucket(1_498), "300_plus", "300 words")
        for words in [0, 9, 10, 49, 50, 149, 150, 299, 300, 5_000] {
            assertEqual(
                bucket(words * WritingAnalytics.charactersPerWord),
                AnalyticsReporter.wordCountBucket(words),
                "\(words) words uses the app's word_count_bucket helper"
            )
        }
    }

    runSuite("WritingAnalytics maps every model and scope to its reviewed enum") {
        assertEqual(WritingAnalytics.modelChoice(.gemma4E2B), "gemma_e2b", "Gemma")
        assertEqual(WritingAnalytics.modelChoice(.qwen35B9B), "qwen_9b", "Qwen")
        assertEqual(
            Set(TildeModelChoice.allCases.map(WritingAnalytics.modelChoice)),
            ["gemma_e2b", "qwen_9b"],
            "every model maps to one of the two documented values"
        )
        assertEqual(WritingAnalytics.AppScope.all.rawValue, "all", "all apps")
        assertEqual(WritingAnalytics.AppScope.picked.rawValue, "picked", "only apps I pick")
    }

    runSuite("WritingAnalytics properties match the allowlist and survive the sanitizer") {
        let daily = WritingAnalytics.dailyCountsProperties(
            .init(suggestionsShown: 3, suggestionsAccepted: 2, acceptedCharacters: 60),
            setup: .init(saveEnabled: false, autocompleteEnabled: false, appScope: .picked, model: .qwen35B9B)
        ) ?? [:]
        let setup = WritingAnalytics.setupProperties(gemmaAll)

        for (event, properties) in [("writing_daily_counts", daily), ("writing_setup_completed", setup)] {
            let policy = AnalyticsEventPolicy.policy(forEvent: event)
            assertEqual(
                policy?.allowedProperties,
                Set(properties.keys),
                "\(event) allows exactly the keys WritingAnalytics sends"
            )
            for key in properties.keys {
                for fragment in PayloadSanitizationCore.baseSensitiveKeyFragments {
                    assertFalse(key.contains(fragment), "\(event).\(key) must not contain \(fragment)")
                }
            }
            let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
                properties,
                allowedKeys: policy?.allowedProperties ?? []
            )
            assertEqual(sanitized, properties, "\(event) reaches PostHog unchanged")
        }
    }
}
