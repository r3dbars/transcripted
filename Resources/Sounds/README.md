# Sounds

`dictation-start.caf` plays when a dictation starts. It is made from "Button 5" by
skyscraper_seven on Pixabay.

`dictation-stop.caf` plays once you press Stop and the mic has stopped, before transcription or paste.
It is made from "Button 14" by skyscraper_seven on Pixabay.

Both clips were changed for Transcripted: the inaudible tail (below -80 dB) was
trimmed (2.55s and 2.78s, down from 3.63s and 3.03s), a 5 ms fade-in and a 0.5s
fade-out were added, and they were re-encoded as AAC in CAF. The app plays them
at 35% volume. They are used under the Pixabay Content
License (https://pixabay.com/service/license-summary/), not the repo's MIT license;
see `THIRD_PARTY_LICENSES.md`.

`dictation-cancelled.wav` and `meeting-transcript-complete.mp3` are the older cues
for cancel/no-speech and a finished meeting transcript.
