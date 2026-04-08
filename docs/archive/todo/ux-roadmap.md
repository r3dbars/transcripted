# Draft UX Roadmap

This is the current UX to-do list for Draft.

The goal is simple:
- keep the app minimal
- make every state easy to understand
- make the value land in dictation and final meeting transcripts

## Product Rules

- Keep floating overlays lightweight.
- Use one clear action per state.
- Put detail in the menubar or transcript, not in the recording pill.
- Use short, human language.
- Prefer calm confirmation over extra controls.

## 1. Make The Final Meeting Transcript Excellent

- [x] Give saved meetings more human titles
- [x] Clean up the transcript header so it is easy to scan
- [x] Improve speaker spacing and formatting
- [x] Make timestamps and metadata easier to read
- [x] Make the final saved transcript feel like the main payoff of the app

## 2. Make The Meeting Flow More Reassuring

- [x] Replace the ambiguous `X` during recording with a clear `Stop` action
- [x] Keep meeting states simple: `Recording`, `Saving transcript`, `Saved`
- [x] Add a lightweight success state after saving
- [x] Make failures feel clear and recoverable
- [x] Remove any remaining states that feel technical or confusing

## 3. Tighten Dictation Feedback

- [x] Make the finish state feel more obvious
- [x] Add clearer paste success feedback
- [x] Add a graceful error state when paste fails
- [x] Keep the dictation overlay minimal and fast
- [x] Make dictation feel reliable in any app

## 4. Make The Menubar Feel Like Home Base

- [x] Keep the top of the menu focused on current status
- [x] Keep shortcuts easy to find and edit
- [x] Keep recent meetings simple and readable
- [x] Keep settings in a tiny footer, not a full control panel
- [x] Make the loading state match the rest of the app

## 5. Improve Transcript Naming

- [x] Replace raw timestamp-heavy names where possible
- [x] Use more human default titles
- [ ] Keep the same title in the menu, file name, and transcript header
- [x] Make transcript names feel useful at a glance

## 6. Add Simple Copy And Export Actions

- [x] Keep `Open` as the primary action
- [x] Add `Copy transcript`
- [x] Add `Reveal in Finder`
- [ ] Consider `Copy for agent` later, but keep it out of the core flow for now
- [x] Keep actions lightweight and obvious

## Not Yet

These matter later, but not before the six items above:

- better onboarding polish
- more graceful retry flows
- richer transcript summaries
- agent-specific export formats
