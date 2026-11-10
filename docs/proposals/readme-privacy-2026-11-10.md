# README privacy wording proposal

Owner decision pending. This preserves frozen PR #2376 as a reviewable proposal.
The integration candidate does not adopt these public privacy promises.

## Proposed change

```diff
diff --git a/README.md b/README.md
index 2b3bdef31..fba75441e 100644
--- a/README.md
+++ b/README.md
@@ -7,7 +7,7 @@
 
 <h1 align="center">Transcripted</h1>
 
-<h3 align="center">Private meeting notes that never leave your Mac. No bot joins your call.</h3>
+<h3 align="center">Meeting notes saved on your Mac. No bot joins your call.</h3>
 
 <p align="center">
   Transcripted is a free, open-source Mac app for meeting notes and dictation.
@@ -183,7 +183,14 @@ Then do steps 3 and 4 above.
 
 ## Privacy
 
-- Your audio, transcripts, and voice profiles never leave your Mac.
+- Recording, transcription, and speaker matching run on your Mac.
+- **Developer Preview → Write for Me** is off by default. When you enable it
+  and use it, it sends the focused window's screenshot and text, matching
+  passages from your saved captures, and examples of your earlier writing to
+  Claude through your signed-in `claude` account.
+- If you send feedback, it sends your message, optional reply address,
+  screenshots you attach, the app version, and any diagnostics you choose to
+  include. You can review the report before sending it.
 - The app keeps meeting audio so you can replay any line. You can have it
   deleted after 7 or 30 days. Transcripts stay.
 - The app sends anonymous crash reports (Sentry) and usage stats (PostHog).
@@ -192,14 +199,16 @@ Then do steps 3 and 4 above.
   paths. The
   [privacy contract](docs/privacy-first-observability.md#privacy-contract) has
   the full list.
-- Writing never sends your text. It sends only counts, like how many
+- Local Autocomplete does not send your text. Its usage stats include counts,
+  like how many
   suggestions you took, and which Writing options you chose. The same usage
   stats switch turns those off.
-- Autocomplete uses the macOS Screen Recording permission to read the text on
-  your screen, mostly the window you're typing in. That text stays in memory
-  on your Mac and is never saved.
-- If you connect a cloud AI like Claude, the notes it reads go to that AI's
-  servers. Transcripted itself never uploads them.
+- Autocomplete uses the macOS Screen Recording permission to read context
+  from the focused window. Screen Memory keeps its snapshots in memory on
+  your Mac.
+- Connecting an agent gives it access to saved captures. Requested content
+  can be sent to that agent's service. The recent-meetings widget can also
+  return retained audio to the connected host.
 
 Where everything is stored: [docs/storage-paths.md](docs/storage-paths.md).
 
@@ -217,9 +226,9 @@ It saves the full transcript, not an AI summary. For a summary, decisions, or
 action items, ask your AI. It answers from your notes.
 
 **Does it work offline?**
-Yes. Recording, transcription, and speaker labels need no internet. The app
-only goes online to check for updates, download optional models, and send the
-crash reports and usage stats above.
+Yes. Recording, transcription, and speaker labels need no internet. Updates
+and optional model downloads use the internet, as do enabled crash reports
+and usage stats, feedback you send, and Developer Preview → Write for Me.
 
 **What languages does it understand?**
 The default model, Parakeet V3, covers 25 European languages, English
```
