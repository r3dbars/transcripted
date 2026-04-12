# Backend

## What this directory is

`archive/backend-beta-worker/` contains the legacy beta proxy and telemetry backend. It is a Cloudflare Worker, not part of the macOS app build.

The current app's core dictation and meeting flows do not depend on this directory. It matters for beta-only update / telemetry / proxy paths.

## Files

- `src/index.ts` — Worker entry point
- `package.json` — local dev and deploy scripts
- `wrangler.toml` — Cloudflare Worker config
- `schema.sql` — D1 schema
- `seed.sql` — seed data
- `queries.sql` — helper queries

## Endpoints in `src/index.ts`

- `POST /v1/messages` — proxy request to Anthropic, log usage
- `POST /events` — ingest event payloads from the app
- `POST /logs` — ingest debug log batches
- `GET /config` — return retained beta config for a user; current macOS app builds on `main` no longer consume its version/update fields
- `GET /admin/usage` — admin-only usage summary

## Environment

The Worker expects bindings / secrets such as:

- `DB`
- `ANTHROPIC_API_KEY`
- `ADMIN_TOKEN`
- `BETA_MESSAGE`
- `LATEST_VERSION`
- `DOWNLOAD_URL`
- `DOWNLOAD_URL_BASE`

## Local commands

```bash
cd archive/backend-beta-worker
npm install
npm run dev
npm run deploy
```

## Agent notes

- This directory is isolated from the Swift app build.
- The current macOS app still uses the worker for beta telemetry/proxy paths, but not for DMG self-update checks.
- If you touch beta-only Swift code in `Sources/Observability/` or `Sources/API/BetaConfig.swift`, verify whether the change also requires a backend change here.
- There is currently no local test harness documented for the Worker; review the SQL schema and endpoint contracts directly before refactoring.
