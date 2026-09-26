# Sounds

`dictation-start.wav` plays the moment you press the dictation key, or once recording
starts when the mic is a Bluetooth headset. It is a single 19 ms tick: a 3.2 kHz sine
with a very fast decay, plus a 3 ms burst of high-passed noise for the edge.

`dictation-stop.wav` plays once you press Stop and the mic has stopped, before
transcription or paste. It is the same idea a step lower: a 20 ms 2.2 kHz tick, so stop
reads as "got it" without sounding like a second start.

`dictation-cancelled.wav` is the "nothing was pasted" cue: a cancelled dictation, a
mis-tap that was too short, or a take with no speech. Meetings play it too when a
recording is cancelled or a queued meeting is discarded. It is a light-switch double
click (an 80 ms pair of short clicks, each a high-passed noise snap over an 800 Hz tick
and a 130 Hz body), rendered at half the peak level of the start and stop ticks because
the app plays it louder.

All three were picked on the Dictation Sound Bench ("Hairline" start and stop,
"Light switch" error) and rendered in code from the bench's synth: 44.1 kHz mono, 16-bit.
The ticks are normalized to a 0.72 peak, the error to 0.36. Start and stop play at 35%
volume. They were made for Transcripted, so they are under the repo's MIT license.

`meeting-transcript-complete.mp3` is the older cue for a finished meeting transcript.

`menu-hover.wav` is the quiet tick when the pointer lands on Record, Dictate, or
Restart to Update in the menu bar menu. It was made for Transcripted in code (a
45 ms 1.85 kHz tone with a fast decay), so it is under the repo's MIT license. The
app plays it at 7% volume, and only when both the app's sounds and the Mac's
"Play user interface sound effects" setting are on.

`menu-row-hover.wav` is the same idea for the rows under the buttons (Open
Transcripted, Check for Updates, Quit): a lower 1.15 kHz tick, 40 ms, played at
about 5% volume. Also made in code and MIT licensed.

`menu-press.wav` is the soft click when you press Record, Restart to Update, or
one of the rows (Dictate has its own start and stop sounds). A 60 ms 620 Hz body
with a short noise snap, made in code, MIT licensed, played at about 10%. None of
the menu sounds play while a meeting or dictation is recording.
