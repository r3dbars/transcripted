# Prompts directory

## Current status

No Swift sources currently live in `Sources/Prompts/` on `main`.

Older docs in this directory described a `PromptStore`, `prompts.json`, and prompt-rewrite flows tied to the removed draft / ghostwriting system. Those sources are not present in the current tree.

## Agent notes

- Do not add code that assumes a live `PromptStore` or `prompts.json` contract without first defining a new source-of-truth API.
- Historical tests and docs may still mention prompt keys such as `ghostwriting_system`; treat those as legacy context, not current runtime truth.
