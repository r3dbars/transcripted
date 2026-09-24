import Foundation

func testDictationLanguageScriptPolicy() {
    runSuite("DictationLanguageScriptPolicy holds back Russian from an English-only Mac") {
        let script = DictationLanguageScriptPolicy.unexpectedScript(
            in: "Перед учителем.",
            userLanguageCodes: ["en-US", "en"]
        )
        assertEqual(script, .cyrillic, "a whole dictation in Cyrillic is a wrong-language guess for an English speaker")
    }

    runSuite("DictationLanguageScriptPolicy keeps text in the person's own languages") {
        assertNil(DictationLanguageScriptPolicy.unexpectedScript(in: "Before the teacher.", userLanguageCodes: ["en-US"]))
        assertNil(
            DictationLanguageScriptPolicy.unexpectedScript(in: "Перед учителем.", userLanguageCodes: ["en-US", "ru-RU"]),
            "a Mac with Russian among its languages may dictate Russian"
        )
        assertNil(
            DictationLanguageScriptPolicy.unexpectedScript(in: "東京に行きます", userLanguageCodes: ["ja_JP"]),
            "Japanese mixes Han and kana"
        )
        assertNil(
            DictationLanguageScriptPolicy.unexpectedScript(in: "Привет, how are you", userLanguageCodes: ["uk"]),
            "Ukrainian is written in Cyrillic too"
        )
    }

    runSuite("DictationLanguageScriptPolicy always accepts Latin text") {
        assertNil(
            DictationLanguageScriptPolicy.unexpectedScript(in: "Send the PDF to Maria", userLanguageCodes: ["ru"]),
            "names, brands and English words show up in every language"
        )
        assertNil(DictationLanguageScriptPolicy.unexpectedScript(in: "Ça va très bien", userLanguageCodes: ["en"]))
    }

    runSuite("DictationLanguageScriptPolicy ignores short, mixed, and unclassified text") {
        assertNil(DictationLanguageScriptPolicy.unexpectedScript(in: "Я", userLanguageCodes: ["en"]), "one letter is too little to judge")
        assertNil(DictationLanguageScriptPolicy.unexpectedScript(in: "123 ... !", userLanguageCodes: ["en"]))
        assertNil(
            DictationLanguageScriptPolicy.unexpectedScript(in: "Meeting with the Иванов team today", userLanguageCodes: ["en"]),
            "a mostly English sentence with one Cyrillic name still pastes"
        )
        assertNil(
            DictationLanguageScriptPolicy.unexpectedScript(in: "வணக்கம் நண்பரே", userLanguageCodes: ["en"]),
            "a script this policy can't classify is never rejected"
        )
    }

    runSuite("DictationLanguageScriptPolicy flags other scripts an English Mac doesn't use") {
        assertEqual(DictationLanguageScriptPolicy.unexpectedScript(in: "你好世界", userLanguageCodes: ["en"]), .han)
        assertEqual(DictationLanguageScriptPolicy.unexpectedScript(in: "Καλημέρα", userLanguageCodes: ["en"]), .greek)
        assertEqual(DictationLanguageScriptPolicy.unexpectedScript(in: "안녕하세요", userLanguageCodes: ["en", "de"]), .hangul)
    }

    runSuite("DictationLanguageScriptPolicy reduces locale identifiers to their language") {
        assertEqual(DictationLanguageScriptPolicy.baseLanguageCode("ru-RU"), "ru")
        assertEqual(DictationLanguageScriptPolicy.baseLanguageCode("zh_Hans_CN"), "zh")
        assertEqual(DictationLanguageScriptPolicy.baseLanguageCode(" EN "), "en")
        assertTrue(DictationLanguageScriptPolicy.expectedScripts(forLanguageCodes: []).contains(.latin))
    }

    runSuite("A wrong-language dictation pastes nothing and says why") {
        let reason = DictationEmptyTranscriptionReason.otherLanguage
        assertEqual(reason.analyticsEventName, "dictation_other_language")
        assertTrue(reason.shouldDiscardStoppedAudioRecovery, "re-running the same audio would guess the same language")
        assertFalse(reason.isAccidentalStart(pressDuration: 0.2))
        let message = DictationNoSpeechPresentationPolicy.message(trigger: "physical_key", reason: reason)
        assertTrue(message.contains("wrong language"))
        assertFalse(message.contains("No speech heard"), "the person did speak")
    }
}
