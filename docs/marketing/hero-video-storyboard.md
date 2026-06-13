# Hero Video Storyboard

The README currently leads with `docs/assets/launch/transcripted-hero.gif`, an
18-second composed tour built from real app screenshots and brand-dark caption
cards. It works, but a real screen recording will beat it. This is the
shot-by-shot script for when you record one.

Target: ~30 seconds, 1200px wide or better, captions baked in, no audio
required. Export both `.mp4` (for the website and social) and a palette-
optimized `.gif` or README-embedded video (drag the `.mp4` into the GitHub
README web editor to get a `user-attachments` URL that plays inline).

## Shots

1. **(0–4s) The hook.** Title card on dark background:
   "A meeting ends. What did you actually agree to?"
2. **(4–9s) Recording.** The meeting recording pill running during a real
   (demo-data) call, then clicking Stop. Caption: "Transcripted records right
   on your Mac — no bot joins the call."
3. **(9–15s) The file.** The finished transcript opening — timestamps, speaker
   names — then `Open Markdown` showing the actual file. Caption: "Every word,
   saved as a plain file you own."
4. **(15–23s) The payoff.** Claude Desktop or Claude Code: type "What did I
   commit to in the product review?" and show the answer quoting the meeting.
   Caption: "Ask your AI. Get receipts."
5. **(23–28s) Dictation.** Hotkey down, speak a sentence, text pastes into a
   visible app (Notes or a code editor). Caption: "One hotkey. Speak. Words
   land where you were typing."
6. **(28–31s) End card.** App icon + "Never lose what was said." +
   "Free · Open source · Nothing leaves your Mac" + transcripted.app.

## Recording rules

- Demo data only (same standard as `docs/launch-assets/README.md` — no real
  names, titles, or paths).
- Capture the full app window. The previous meeting-recording capture was
  clipped on the right edge and shipped that way; check edges before exporting.
- Slow down: each on-screen state needs ~2.5s minimum to read.
- Keep the dark appearance — it matches the banner and the hero GIF.

## One-time GitHub setting (manual)

Upload `docs/assets/social-preview.png` (1280×640, already generated) at
**GitHub repo → Settings → General → Social preview**. Until that's done,
shares of the repo on X/Slack/Discord show GitHub's auto-generated stats card
instead of the brand banner.
