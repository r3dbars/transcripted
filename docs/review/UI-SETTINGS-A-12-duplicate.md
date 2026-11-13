# UI-SETTINGS-A-12: duplicate shortcut-recorder ownership finding

UI-SETTINGS-A-12 and UI-SETTINGS-B-6 identify the same concern: closing Settings
mid-recording can leave shortcut monitors listening across app windows. The
shared implementation proposal is [PR #2459](https://github.com/r3dbars/transcripted/pull/2459),
at commit `f39a4fa5df48bfc9c263823e6e0006f018dd716f`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. B6 remains its primary report ID.

The proposal binds both `ShortcutRecorderModel` and the Write for Me key row to
the visible window that started recording. A close observer stops recording;
foreign or missing event windows pass through and clear pending modifiers.
Stopping also removes the observer. Admitted events continue through the
existing key validation and save logic. The five-file patch includes the shared
admission policy, its fixture and the fast-runner source-list entry.

The existing PR records independent review and 16 focused policy assertions,
plus three expected failures when foreign-window admission was deliberately
allowed. Those are its recorded results, not tests rerun for this document.
Actual AppKit observer wiring, closing and reopening Settings, modifier-only
recording and typing into other app windows still need native verification.

This document gives A12 its own reviewable disposition without repeating the
implementation. At verification, #2459 is an open, unmerged draft; its broader
fast-suite safety refusal and skipped UI/speed proof remain recorded there.
Accepting this disposition alone does not apply the fix or establish native
keyboard, window-close, account-isolation or hardware proof.
