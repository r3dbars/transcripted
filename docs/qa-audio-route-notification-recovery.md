# Audio route notification recovery QA

Automated blocked-lookup tests establish timeout, bounded worker retention,
ordered observer delivery, and shutdown handling. They do not establish that a
physical USB driver publishes its route or audio samples correctly.

On a Mac with built-in input and a representative USB microphone (including a
Logitech C920 where available), exercise these states separately: idle, active
dictation, dictation starting, and dictation stopping. Change the Mac default
input to USB; unplug and reconnect the device during speech; then return to
built-in input. Repeat with Faster Bluetooth dictation enabled if applicable.

For each route transition, confirm that the UI stays responsive, recovery
either resumes accurate capture from the selected microphone or fails clearly,
and a failed/unknown route never reports microphone-ready based only on stale
formats. Check that the first and last spoken words survive recovery, no
recording restarts after user stop, and repeated notifications do not accumulate
blocked workers or audio graphs. A real microphone pass must also verify the
captured source by speaking near one input while muting or distancing the other.

Record the app version, macOS version, input transport/class, input format,
route-selection reason, binding outcome, format readiness, sample-flow state,
and elapsed recovery stages in redacted diagnostics. Do not attach raw audio,
transcript text, device names, meeting titles, or other private content.
