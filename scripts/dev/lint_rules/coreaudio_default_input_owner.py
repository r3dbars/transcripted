"""coreaudio-default-input-owner: the Mac-wide default input has one owner.

The default input device (`kAudioHardwarePropertyDefaultInputDevice`) is shared
state for the whole Mac. Writing it per session flipped AirPods between call
mode and music mode, added a ~470 ms start tax and made
`PersistentDictationInputController` misread the app's own writes as the user's
(14d3cb1ba). Three separate listeners on it raced each other and couldn't tell
the app's writes from the user's (8cd7d7152). Both fixes made one owner:

  - reads: `CoreAudioInputDeviceLookup.currentDefaultInputDeviceID()`
    (Speech) or `AudioDeviceID.readDefaultInputDevice()` (Core audio)
  - change notifications: subscribe to `DefaultInputDeviceMonitor.shared`
  - writes: only `PersistentDictationInputController`, through
    `DefaultInputDeviceMonitor.shared.setDefaultInputDevice(_:)` so the monitor
    marks them as self-writes

Three shapes are flagged, on comment- and string-blanked code:
  1. the `kAudioHardwarePropertyDefaultInputDevice` selector outside the owner
     files (a raw read, write or listener)
  2. `.setDefaultInputDeviceID(` (the raw write) outside DefaultInputDeviceMonitor
  3. `.setDefaultInputDevice(` (the monitored write) outside
     PersistentDictationInputController and the monitor

Out of scope: `AVAudioEngine.inputNode` (it binds the default input on first
touch, the other half of the AirPods trap). Its uses are spread over the
dictation and meeting engine files and no fix has moved one yet, so there's no
owner to point at. Calls through a local alias of the selector are missed.
"""

from __future__ import annotations

import re

from lint_rules._base import swift_file

RULE = {
    "id": "coreaudio-default-input-owner",
    "summary": "the Mac-wide default input (kAudioHardwarePropertyDefaultInputDevice) is read, watched or written only "
               "through its owners",
    "why": "per-session default-input writes flipped AirPods into call mode and broke PersistentDictationInputController "
           "(14d3cb1ba, #1702); three direct listeners raced and misread the app's own writes (8cd7d7152)",
    "fix": "read with CoreAudioInputDeviceLookup.currentDefaultInputDeviceID() (Speech) or "
           "AudioDeviceID.readDefaultInputDevice() (Core), subscribe to DefaultInputDeviceMonitor.shared for changes, "
           "and never write it per session; mic choice binds only the app's own AUHAL "
           "(applyPreferredDictationInputDevice). See the AirPods rules in Sources/Speech/AGENTS.md",
    "owner_doc": "Sources/Speech/AGENTS.md",
    "level": "lint",
    "paths": ["Sources/**/*.swift", "Tools/**/*.swift"],
    "exclude": [],
    "ratchet": True,
    "proof": [
        # 14d3cb1ba^: every dictation start wrote the Mac-wide default input and restored it at stop.
        "1f7b3183a910bd6e5d8b8221b7161ea4de22edb6:Sources/Speech/ParakeetEngine.swift",
        # 8cd7d7152^: three direct listeners on the default-input property.
        "d900b60dfb309e5821dadad65bb8effb025d2680:Sources/Speech/ParakeetDeviceRecovery.swift",
        "d900b60dfb309e5821dadad65bb8effb025d2680:Sources/Speech/PersistentDictationInputController.swift",
        "d900b60dfb309e5821dadad65bb8effb025d2680:Sources/Meeting/MicActivityMonitor.swift",
    ],
}

_SELECTOR = re.compile(r"\bkAudioHardwarePropertyDefaultInputDevice\b")
_RAW_WRITE = re.compile(r"\.\s*setDefaultInputDeviceID\s*\(")
_MONITORED_WRITE = re.compile(r"\.\s*setDefaultInputDevice\s*\(")

_SELECTOR_OWNERS = frozenset({
    "Sources/Speech/DefaultInputDeviceMonitor.swift",
    "Sources/Speech/DefaultInputDeviceMonitorSupport.swift",
    "Sources/Speech/ParakeetAudioDeviceLookup.swift",
    "Sources/TranscriptedCore/Audio/CoreAudioUtils.swift",
})
_RAW_WRITE_OWNERS = frozenset({"Sources/Speech/DefaultInputDeviceMonitor.swift"})
_MONITORED_WRITE_OWNERS = frozenset({
    "Sources/Speech/DefaultInputDeviceMonitor.swift",
    "Sources/Speech/PersistentDictationInputController.swift",
    "Sources/Speech/PersistentDictationInputController+Live.swift",
})

SELECTOR_MSG = ("raw `kAudioHardwarePropertyDefaultInputDevice` outside its owners: read it with "
                "`CoreAudioInputDeviceLookup.currentDefaultInputDeviceID()` (Speech) or "
                "`AudioDeviceID.readDefaultInputDevice()` (Core), and subscribe to `DefaultInputDeviceMonitor.shared` "
                "instead of adding a listener; never write it (Sources/Speech/AGENTS.md, AirPods rules)")
RAW_WRITE_MSG = ("`setDefaultInputDeviceID` writes the Mac-wide default input behind the monitor's back, so "
                 "PersistentDictationInputController reads it as the user's choice and AirPods flip routes; don't "
                 "write the default input per session, bind the app's own AUHAL (applyPreferredDictationInputDevice)")
MONITORED_WRITE_MSG = ("only PersistentDictationInputController may write the Mac-wide default input "
                       "(`DefaultInputDeviceMonitor.shared.setDefaultInputDevice`); pick the mic for this app with "
                       "applyPreferredDictationInputDevice, which binds only Transcripted's own AUHAL")


def check(path: str, text: str):
    if ("kAudioHardwarePropertyDefaultInputDevice" not in text
            and "setDefaultInputDevice" not in text):
        return []
    sf = swift_file(text)
    out = []
    if path not in _SELECTOR_OWNERS:
        out += [(line, SELECTOR_MSG) for line, _ in sf.find(_SELECTOR)]
    if path not in _RAW_WRITE_OWNERS:
        out += [(line, RAW_WRITE_MSG) for line, _ in sf.find(_RAW_WRITE)]
    if path not in _MONITORED_WRITE_OWNERS:
        out += [(line, MONITORED_WRITE_MSG) for line, _ in sf.find(_MONITORED_WRITE)]
    out.sort()
    return out
