# AXMeetingProbe (prototype, not shipped)
Standalone CLI to study how Zoom / Teams / Google Meet (Chrome, Arc, Edge, Safari) expose
participant tiles and the active speaker through macOS Accessibility. Supports
`zoom-name-reader-design.md`. Written from scratch; no rival code or assets.

    swift run AXMeetingProbe dump  [--app zoom|teams|meet] [--depth 25]   # print the meeting window AX tree
    swift run AXMeetingProbe watch [--app zoom|teams|meet] [--hz 2]       # print roster + guessed active speaker

The terminal running it needs the Accessibility permission. `--redact` replaces names with hashes so dumps can become test fixtures.
Heuristics are guesses to be confirmed against real dumps.
