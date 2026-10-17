// DictationShortcutUpgradeTests.swift
// Promises the 1.1.69 → one-key upgrade: everyone lands on one dictation
// key (Right Option, or a custom Hands-Free key), never Fn restored, never
// two keys bound. The three suites load the same UserDefaults keys 1.1.69
// actually wrote (or left unwritten for defaults), not today's save helpers.
//
// On 1.1.70 main these fail: (a) does not persist Right Option or arm the
// notice; (b) leaves stored Fn; (c) leaves stored Fn and drops the custom key.

import Carbon
import Foundation

func testDictationShortcutUpgrade() {
    let fn = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))
    let rightOption = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
    let f5 = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_F5))

    runSuite("1.1.69 default keys: one Right Option key and the moved-key notice") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)

        assertOneDictationKey(
            bindings,
            binding: rightOption,
            "unstored 1.1.69 defaults must become the one Right Option key, not Fn"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.storedPushToTalkBinding(userDefaults: defaults),
            Optional(rightOption),
            "the upgrade must persist Right Option so a later default change cannot move them"
        )
        assertTrue(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: defaults),
            "upgrading from 1.1.69 must show the one-time moved-key notice"
        )
        assertEqual(
            DictationShortcutUpgrade.movedToRightOptionNotice,
            "Dictation moved to Right Option",
            "the notice names the new key"
        )
        assertEqual(
            DictationShortcutUpgrade.movedToRightOptionNoticeIdentifier,
            "transcripted.settings.general.dictation-key-moved-note",
            "Settings can find the notice by the same automation id"
        )
        assertEqual(
            DictationShortcutUpgrade.movedToRightOptionNoticeDismissIdentifier,
            "transcripted.settings.general.dictation-key-moved-note-dismiss",
            "OK uses a stable dismiss id"
        )
        assertEqual(
            HotkeyPreferences.dictationKeyBehavior(userDefaults: defaults),
            .holdOrTap,
            "the one-key default behavior stays Hold or tap"
        )
    }

    runSuite("1.1.69 reset-to-defaults: stored Fn becomes Right Option, not left as the only key") {
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

        assertOneDictationKey(
            bindings,
            binding: rightOption,
            "reset-to-defaults on 1.1.69 stored Fn; the upgrade must not leave them on Fn"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.storedHandsFreeBinding(userDefaults: defaults),
            "the leftover Hands-Free slot is cleared so a second key cannot register"
        )
        assertTrue(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: defaults),
            "moving stored Fn to Right Option arms the notice"
        )
        assertEqual(
            bindings.map(\.action).filter { $0 == .meeting }.count,
            1,
            "meetings stay registered"
        )
        assertEqual(
            bindings.count,
            2,
            "one dictation key plus meetings; paste-last stays gone"
        )
    }

    runSuite("1.1.69 Fn plus a custom hands-free key: the custom key becomes the one dictation key") {
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

        assertOneDictationKey(
            bindings,
            binding: f5,
            "a custom Hands-Free key is kept as the one dictation key"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.storedHandsFreeBinding(userDefaults: defaults),
            "Hands-Free is folded into the one key, not bound beside it"
        )
        assertEqual(
            HotkeyPreferences.dictationKeyBehavior(userDefaults: defaults),
            .tapToToggle,
            "the custom Hands-Free chord was press-to-fire"
        )
        assertFalse(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: defaults),
            "they kept F5, so 'moved to Right Option' would be wrong"
        )
        assertFalse(
            bindings.contains { $0.binding == fn },
            "Fn is not restored next to the custom key"
        )
    }

    runSuite("The moved-key notice is one-time, dismissed, and skipped for fresh and 1.1.70+ installs") {
        let (upgrader, upgraderSuite) = makeDictationShortcutUpgradeDefaults()
        defer { upgrader.removePersistentDomain(forName: upgraderSuite) }
        seedReal1169Identity(in: upgrader)
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: upgrader)
        assertTrue(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: upgrader),
            "1.1.69 upgraders who land on Right Option see the notice"
        )
        DictationShortcutUpgrade.dismissMovedToRightOptionNotice(userDefaults: upgrader)
        assertFalse(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: upgrader),
            "OK persists the dismissal"
        )
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: upgrader)
        assertFalse(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: upgrader),
            "migrate runs once, so a later launch does not re-arm the notice"
        )

        let (fresh, freshSuite) = makeDictationShortcutUpgradeDefaults()
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: fresh)
        assertFalse(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: fresh),
            "a fresh install never sees the upgrade notice"
        )

        let (already, alreadySuite) = makeDictationShortcutUpgradeDefaults()
        defer { already.removePersistentDomain(forName: alreadySuite) }
        already.set("1.1.70", forKey: "Transcripted.LastLaunchedAppVersion")
        already.set(true, forKey: "permissionsOnboardingCompleted")
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: already)
        assertFalse(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: already),
            "anyone already on 1.1.70 or later does not see the notice"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.storedPushToTalkBinding(userDefaults: already),
            "1.1.70+ unstored defaults stay unstored Right Option, not a rewrite"
        )
    }

    runSuite("Sparkle overwriting last-launched to 1.1.70 still shows the notice for 1.1.69") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)
        DictationShortcutUpgrade.rememberPreviousLaunchedVersion("1.1.69", userDefaults: defaults)
        defaults.set("1.1.70", forKey: "Transcripted.LastLaunchedAppVersion")

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)

        assertOneDictationKey(
            PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults),
            binding: rightOption,
            "the previous-version snapshot is what migrate sees after Sparkle writes 1.1.70"
        )
        assertTrue(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: defaults),
            "Sparkle's overwrite must not hide the notice from a 1.1.69 upgrader"
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
        let optionSpace = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: PhysicalDictationTriggerModifiers.option
        )

        assertOneDictationKey(
            PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults),
            binding: optionSpace,
            "disabled Right Option must keep the Carbon Option+Space shortcut"
        )
        assertFalse(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: defaults),
            "they kept Option+Space, so 'moved to Right Option' would be wrong"
        )
    }

    runSuite("A harness launch does not write upgrade flags") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(
            userDefaults: defaults,
            isAutomatedLaunch: true
        )
        DictationShortcutUpgrade.apply(userDefaults: defaults, isAutomatedLaunch: true)

        assertFalse(
            defaults.bool(forKey: "dictationOneKeyMigrated"),
            "smokes must not mark the one-key migrate as done"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.storedPushToTalkBinding(userDefaults: defaults),
            "smokes use a throwaway HOME and must not persist Right Option"
        )
        assertFalse(
            DictationShortcutUpgrade.showsMovedToRightOptionNotice(userDefaults: defaults),
            "smokes must not arm the moved-key notice"
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
            PhysicalDictationTriggerPreferences.displayString(
                for: PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults)
            ),
            "Right ⌥",
            "the menu bar shows one key"
        )
    }

    runSuite("Chosen-shortcut analytics names are categorical and dictation captures include build_channel") {
        let (defaults, suiteName) = makeDictationShortcutUpgradeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        seedReal1169Identity(in: defaults)
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)

        let properties = DictationShortcutUpgrade.analyticsProperties(userDefaults: defaults)
        assertEqual(properties["hold_key"], "right_option", "the one key is Right Option")
        assertEqual(properties["toggle_key"], "right_option", "there is no second toggle key")
        assertEqual(properties["key_behavior"], "hold_or_tap", "behavior stays Hold or tap")

        let allowed = Set(properties.keys)
        let walked = AnalyticsPayloadSanitizer.sanitizeProperties(properties, allowedKeys: allowed)
        assertEqual(walked, properties, "hold_key, toggle_key, and key_behavior must not be dropped by substring sanitizing")

        let dictationPolicy = AnalyticsEventPolicy.policy(forEvent: "dictation_started")
        assertNotNil(dictationPolicy, "dictation_started is allowlisted")
        let eventAllowed = dictationPolicy!.allowedProperties
        for key in ["hold_key", "toggle_key", "key_behavior"] {
            assertTrue(eventAllowed.contains(key), "\(key) must be on the dictation_started allowlist")
        }

        let sanitizedForEvent = AnalyticsPayloadSanitizer.sanitizeProperties(
            properties,
            allowedKeys: eventAllowed
        )
        let capture = AnalyticsReporter.captureProperties(
            sanitizedProperties: sanitizedForEvent,
            distinctID: "anonymous-device",
            sessionID: "00000000-0000-0000-0000-000000000001",
            infoDictionary: [AnalyticsInfoPlistKeys.buildChannelInfoKey: "local"]
        )
        assertEqual(
            capture["build_channel"],
            "local",
            "dictation_started captures carry local vs release so dashboards can drop local Macs"
        )
        assertEqual(capture["hold_key"], "right_option", "chosen-shortcut properties survive onto the capture")
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

private func assertOneDictationKey(
    _ bindings: [PhysicalShortcutBinding],
    binding: PhysicalDictationTriggerBinding,
    _ message: String,
    file: String = #file,
    line: Int = #line
) {
    let dictation = bindings.filter {
        $0.action == .dictationPushToTalk || $0.action == .dictationHandsFree
    }
    assertEqual(dictation.count, 1, "\(message): exactly one dictation key", file: file, line: line)
    assertEqual(dictation.first?.binding, Optional(binding), message, file: file, line: line)
    assertFalse(
        bindings.contains { $0.binding == PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function)) },
        "\(message): Fn must not be registered",
        file: file,
        line: line
    )
}
