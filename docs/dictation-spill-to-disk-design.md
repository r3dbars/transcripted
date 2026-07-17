# Dictation Spill-To-Disk Design

Transcripted currently keeps active dictation audio in memory until stop. A crash or force quit can lose the whole in-flight dictation. This note defines the safe implementation shape for adding recovery without doing risky audio callback work in the first PR.

## Contract

- Create a session-scoped spill plan when dictation capture starts.
- Write borrowed tap buffers to memory first, then enqueue copied PCM frames to a single utility writer queue.
- Rotate fixed-duration PCM chunks, defaulting to 10 seconds.
- Maintain a small JSON journal next to the chunks with session id, sample rate, chunk order, start time, and last completed chunk.
- Keep at most five minutes recoverable by default.
- Delete the journal and chunks only after normal dictation save completes.
- On launch, scan journals, validate chunk filenames stay inside the spill directory, and offer recovered dictation transcription.

## Non-goals For This Slice

- No file I/O from the CoreAudio callback.
- No recovery UI yet.
- No transcription from spill chunks yet.

This remains a design proposal. No spill-to-disk implementation currently ships. When implemented, land the writer, journal recovery, and end-to-end tests together instead of keeping an unused planning type in production Core.
