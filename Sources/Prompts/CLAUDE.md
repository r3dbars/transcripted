# Prompts Folder

## Current State

This folder is currently a placeholder and does not contain active Swift sources.

The older centralized prompt-store system described in previous docs is not part of the live Transcripted app on this branch. Prompt text that still exists in the product now lives next to the feature that uses it rather than in a shared `PromptStore`.

## Guidance

- Do not assume a `prompts.json` contract exists in the current app.
- Do not reintroduce a shared prompt layer without also wiring it into `DraftAppState`, tests, and storage-path docs.
- If this folder becomes active again, update this file first so it reflects the real ownership model instead of the retired one.
