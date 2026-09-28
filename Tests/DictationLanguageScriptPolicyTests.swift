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

    runSuite("DictationLanguageScriptPolicy pastes English with a foreign-script name in it") {
        for text in ["Call Олег", "Meet Иван", "OK 你好", "Ask 王先生", "Email Дмитрий", "Send it to Александр", "Δt"] {
            assertNil(
                DictationLanguageScriptPolicy.unexpectedScript(in: text, userLanguageCodes: ["en"]),
                "\(text) is English with a name, not a wrong-language guess"
            )
        }
        assertNil(DictationLanguageScriptPolicy.dominantNonLatinScript(in: "Before the teacher."))
        assertEqual(DictationLanguageScriptPolicy.dominantNonLatinScript(in: "Перед учителем."), .cyrillic)
    }

    runSuite("DictationLanguageScriptPolicy knows less common language codes") {
        for code in ["bs", "cnr"] {
            assertTrue(DictationLanguageScriptPolicy.isExpected(.cyrillic, userLanguageCodes: [code]), code)
        }
        for code in ["ckb", "pnb"] {
            assertTrue(DictationLanguageScriptPolicy.isExpected(.arabic, userLanguageCodes: [code]), code)
        }
    }

    runSuite("A wrong-language dictation keeps its audio and offers Paste Anyway") {
        let reason = DictationEmptyTranscriptionReason.otherLanguage
        assertEqual(reason.analyticsEventName, "dictation_other_language")
        assertFalse(reason.shouldDiscardStoppedAudioRecovery, "the check can be wrong, so the recording must survive")
        assertFalse(reason.isAccidentalStart(pressDuration: 0.2))
        let message = DictationNoSpeechPresentationPolicy.message(trigger: "physical_key", reason: reason)
        assertTrue(message.contains(DictationHeldTextActionCopy.pasteAnywayTitle), "the message names its button")
        assertFalse(message.contains("switch transcription models"), "switching models doesn't help someone who spoke that language")
        assertFalse(message.contains("No speech heard"), "the person did speak")
    }

    runSuite("The stop path offers the held-back text instead of dropping it") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let controller = (try? String(
            contentsOf: root.appendingPathComponent("Sources/UI/Overlay/DictationSessionController.swift"),
            encoding: .utf8
        )) ?? ""
        assertTrue(controller.contains("let heldText = appState.sttRouter.heldBackDictationText"))
        assertTrue(controller.contains("let outcome = self.pasteWithClipboardRestore(heldText)"))
        assertTrue(
            controller.contains("text: heldText,\n                                delivery: outcome.delivery,\n                                recovery: heldRecovery"),
            "Paste Anyway saves the take and cleans up its kept audio like any finished dictation"
        )
        let router = (try? String(
            contentsOf: root.appendingPathComponent("Sources/Speech/STTRouter.swift"),
            encoding: .utf8
        )) ?? ""
        assertTrue(router.contains("heldBackDictationText = text"))
    }
}
