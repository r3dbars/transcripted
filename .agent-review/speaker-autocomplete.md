# Speaker name typing regression

Base: `5b88bd5ee` (`origin/main` at investigation).

The actual `SpeakerNameAutocompleteField` was hosted in `NSHostingView` with
one synthetic saved person, `Samuel Example`. Synthetic key events were sent
to its AppKit field editor with a SwiftUI update turn between each event.

| Input | Original editor / binding | Fixed editor / binding |
| --- | --- | --- |
| `Sam ` | `Samuel Example`, selected range `{4,10}` | `Sam `, caret `{4,0}` |
| continue with `Test` | `SamuTest` | `Sam Test`, caret `{8,0}` |

The field enabled `NSComboBox.completes` and returned a unique prefix completion
from `completedString`. Matching normalizes by trimming whitespace, so `Sam `
again matched `Samuel Example`. The field has had this path since its introduction
in `7d42c7922`; subsequent lifetime and identity fixes did not remove it.

The fix disables native inline completion. Suggestions remain in the filtered
dropdown, whose explicit selection still resolves the saved person's UUID and
plain display name. It leaves AppKit in charge of selection and composition.

## Proof

- Production AppKit field tests cover per-character typing, spaces, caret edits,
  replacement of a selection, backspace, bulk insertion, marked text, composition
  commit, non-first duplicate-label UUID mapping, clearing that identity on edits,
  and Return submitting the typed name.
- Restoring both original inline-completion settings in a temporary source copy
  makes seven typing/caret assertions fail, including the first `Sam ` assertion.
- A separate SwiftUI-hosted field probe preserved middle-caret insertion,
  `Sam Pasted` bulk insertion, marked `Sam ` across an update turn, and its
  `Sam Composed` commit.
- Independent read-only full-diff review found no blocking findings.
- [Rendered synthetic field](visuals/speaker-name-typed-space.png).

## Limits

The historical customer setup was not reproduced. The synthetic reproduction
establishes a current code defect consistent with the report, not its exact
historical cause. The identity regression drives AppKit's selection delegate;
it does not automate a physical mouse/keyboard dropdown gesture. Bulk insertion
models paste without reading or replacing the user's clipboard. A separate
named-pasteboard probe was unavailable under the local sandbox. Composition is
synthetic NSTextInputClient input, not a complete installed-IME interaction.
