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

    runSuite("Onboarding-completed 1.1.69 defaults keep Fn after last-launched is already 1.1.70") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("1.1.70", forKey: "Transcripted.LastLaunchedAppVersion")
        defaults.set(true, forKey: "permissionsOnboardingCompleted")

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)

        assertUpgradedTwoKeyLayout(
            bindings,
            hold: fn,
            toggle: rightOption,
            "registerHotkey runs after Sparkle writes 1.1.70, so onboarding is the remaining 1.1.69 signal"
        )
    }

    runSuite("Sparkle overwriting last-launched to 1.1.70 still keeps 1.1.69 default keys") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)
        DictationShortcutUpgrade.rememberPreviousLaunchedVersion("1.1.69", userDefaults: defaults)
        defaults.set("1.1.70", forKey: "Transcripted.LastLaunchedAppVersion")

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)

        assertUpgradedTwoKeyLayout(
            bindings,
            hold: fn,
            toggle: rightOption,
            "the previous-version snapshot is what migrate sees after Sparkle writes 1.1.70"
        )
    }

    runSuite("A leftover 1.1.69 Hands-Free key still fires after the one-key flag is set") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("1.1.70", forKey: "Transcripted.LastLaunchedAppVersion")
        defaults.set(true, forKey: "dictationOneKeyMigrated")
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

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)

        assertUpgradedTwoKeyLayout(
            bindings,
            hold: fn,
            toggle: rightOption,
            "already-upgraded reset-to-defaults users still have the Hands-Free keys on disk"
        )
    }

    runSuite("Carbon-era Option+Space with Right Option off stays the one dictation key") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        HotkeyPreferences.setRightOptionDictation(enabled: false, userDefaults: defaults)
        HotkeyPreferences.save(
            dictation: HotkeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
            userDefaults: defaults
        )

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)
        let optionSpace = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: PhysicalDictationTriggerModifiers.option
        )

        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            optionSpace,
            "disabled Right Option must keep the Carbon Option+Space shortcut"
        )
        assertEqual(
            bindings.first { $0.action == .dictationPushToTalk }?.binding,
            Optional(optionSpace),
            "the event tap must register Option+Space, not Right Option"
        )
        assertNil(
            bindings.first { $0.action == .dictationHandsFree },
            "this cohort had one Carbon key, not the 1.1.69 two-key layout"
        )
        assertEqual(
            HotkeyPreferences.dictationKeyBehavior(userDefaults: defaults),
            .tapToToggle,
            "Carbon RegisterEventHotKey was press-to-fire, which maps to Tap to toggle"
        )
    }

    runSuite("A fresh install still has one dictation key, Right Option") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)

        assertEqual(
            bindings.map(\.action),
            [.dictationPushToTalk, .meeting],
            "new installs must not gain a second 1.1.69 Hands-Free key"
        )
        assertEqual(
            bindings.first?.binding,
            rightOption,
            "the product default stays Right Option"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.dictationShortcutDisplayString(userDefaults: defaults),
            "Right ⌥",
            "the menu bar shows one key"
        )
    }

    runSuite("Chosen-shortcut analytics names are categorical and survive sanitizing") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)

        let properties = DictationShortcutUpgrade.analyticsProperties(userDefaults: defaults)
        assertEqual(properties["hold_key"], "fn", "the hold key is Fn")
        assertEqual(properties["toggle_key"], "right_option", "the toggle key is Right Option")
        assertEqual(properties["key_behavior"], "hold_or_tap", "behavior stays Hold or tap")
        assertEqual(
            PhysicalDictationTriggerPreferences.dictationShortcutDisplayString(userDefaults: defaults),
            "Fn / Right ⌥",
            "the menu bar shows both keys"
        )

        let allowed = Set(properties.keys)
        let walked = AnalyticsPayloadSanitizer.sanitizeProperties(properties, allowedKeys: allowed)
        assertEqual(walked, properties, "hold_key, toggle_key, and key_behavior must not be dropped by substring sanitizing")
        assertEqual(
            AnalyticsReporter.defaultProperties(
                distinctID: "anonymous-device",
                sessionID: "session-1",
                infoDictionary: [AnalyticsInfoPlistKeys.buildChannelInfoKey: "local"]
            )["build_channel"],
            "local",
            "dictation events already carry local vs release on every capture"
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
