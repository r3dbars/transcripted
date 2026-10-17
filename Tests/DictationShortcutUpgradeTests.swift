// DictationShortcutUpgradeTests.swift
// Promises the 1.1.69 → 1.1.70 shortcut upgrade must keep: every key that
// still worked on 1.1.69 still fires after migrate + the event-tap snapshot.
// The three suites load the same UserDefaults keys 1.1.69 actually wrote
// (or left unwritten for defaults), not today's save helpers.

import Carbon
import Foundation

func testDictationShortcutUpgrade() {
    let fn = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))
    let rightOption = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
    let f5 = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_F5))

    runSuite("1.1.69 default keys: Fn hold and Right Option hands-free both still work after upgrade") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)

        assertUpgradedTwoKeyLayout(
            bindings,
            hold: fn,
            toggle: rightOption,
            "unstored 1.1.69 defaults were Fn hold-to-talk and Right Option hands-free"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            fn,
            "Settings should still show Fn as the hold key"
        )
        assertEqual(
            HotkeyPreferences.dictationKeyBehavior(userDefaults: defaults),
            .holdOrTap,
            "the one-key fold must not switch them to Tap to toggle"
        )
    }

    runSuite("1.1.69 reset-to-defaults: Fn hold and Right Option hands-free both still work after upgrade") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)
        // 1.1.69 resetToDefaults wrote both physical keys (Fn + Right Option)
        // plus meetings and paste-last. Paste-last must stay unregistered.
        seedStoredPhysicalKey(
            keyCodeKey: "dictationPushToTalkTrigger-keyCode",
            modifiersKey: "dictationPushToTalkTrigger-modifiers",
            binding: fn,
            in: defaults
        )
        seedStoredPhysicalKey(
            keyCodeKey: "dictationHandsFreeTrigger-keyCode",
            modifiersKey: "dictationHandsFreeTrigger-modifiers",
            binding: rightOption,
            in: defaults
        )
        seedStoredPhysicalKey(
            keyCodeKey: "meetingTrigger-keyCode",
            modifiersKey: "meetingTrigger-modifiers",
            binding: PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            in: defaults
        )
        seedStoredPhysicalKey(
            keyCodeKey: "pasteLastDictationTrigger-keyCode",
            modifiersKey: "pasteLastDictationTrigger-modifiers",
            binding: PhysicalDictationTriggerBinding(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.shift
            ),
            in: defaults
        )

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)

        assertUpgradedTwoKeyLayout(
            bindings,
            hold: fn,
            toggle: rightOption,
            "reset-to-defaults on 1.1.69 stored Fn hold and Right Option hands-free"
        )
        assertEqual(
            bindings.map(\.action).filter { $0 == .meeting }.count,
            1,
            "meetings stay registered"
        )
        assertEqual(
            bindings.count,
            3,
            "two dictation keys plus meetings; paste-last stays gone"
        )
    }

    runSuite("1.1.69 Fn plus a custom hands-free key: both keys still work after upgrade") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)
        seedStoredPhysicalKey(
            keyCodeKey: "dictationPushToTalkTrigger-keyCode",
            modifiersKey: "dictationPushToTalkTrigger-modifiers",
            binding: fn,
            in: defaults
        )
        seedStoredPhysicalKey(
            keyCodeKey: "dictationHandsFreeTrigger-keyCode",
            modifiersKey: "dictationHandsFreeTrigger-modifiers",
            binding: f5,
            in: defaults
        )

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)

        assertUpgradedTwoKeyLayout(
            bindings,
            hold: fn,
            toggle: f5,
            "a custom Hands-Free key is a second dictation key, not a replacement for Fn"
        )
        assertEqual(
            HotkeyPreferences.dictationKeyBehavior(userDefaults: defaults),
            .holdOrTap,
            "keeping the custom key must not fold it into Tap to toggle"
        )
    }
}

private func makeDictationShortcutUpgradeDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationShortcutUpgradeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

/// The keys a 1.1.69 install actually had after onboarding, before 1.1.70
/// rewrote the dictation defaults. Defaults themselves were unstored.
private func seedReal1169Identity(in defaults: UserDefaults) {
    defaults.set("1.1.69", forKey: "Transcripted.LastLaunchedAppVersion")
    defaults.set(true, forKey: "permissionsOnboardingCompleted")
}

private func seedStoredPhysicalKey(
    keyCodeKey: String,
    modifiersKey: String,
    binding: PhysicalDictationTriggerBinding,
    in defaults: UserDefaults
) {
    defaults.set(Int(binding.keyCode), forKey: keyCodeKey)
    defaults.set(Int(binding.modifiers), forKey: modifiersKey)
}

private func assertUpgradedTwoKeyLayout(
    _ bindings: [PhysicalShortcutBinding],
    hold: PhysicalDictationTriggerBinding,
    toggle: PhysicalDictationTriggerBinding,
    _ message: String,
    file: String = #file,
    line: Int = #line
) {
    let holdMatch = bindings.first { $0.binding == hold }
    let toggleMatch = bindings.first { $0.binding == toggle }
    assertEqual(
        holdMatch?.action,
        Optional(.dictationPushToTalk),
        "\(message): Fn-style hold must stay Push to Talk",
        file: file,
        line: line
    )
    assertEqual(
        toggleMatch?.action,
        Optional(.dictationHandsFree),
        "\(message): the second key must stay Hands-Free",
        file: file,
        line: line
    )
}
