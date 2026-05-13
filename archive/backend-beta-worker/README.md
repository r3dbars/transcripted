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

- `POST /events` — ingest event payloads from the app
- `POST /logs` — ingest debug log batches
- `GET /config` — return retained beta config for a user; current macOS app builds on `main` no longer consume its version/update fields
- `GET /admin/usage` — admin-only usage summary

The historical `POST /v1/messages` route, which proxied to Anthropic using a
worker-side `ANTHROPIC_API_KEY`, was removed. If you redeploy from this archive,
the route is gone. The current app on `main` does not chat with Anthropic via
this worker, so there is no caller to break. If the live worker at
`draft-proxy.tz427gsydr.workers.dev` still has the old route, redeploy from this
archive (or take the worker offline) and rotate any `ANTHROPIC_API_KEY` that was
ever set in the worker's secrets.

## Environment

The Worker expects bindings / secrets such as:

- `DB`
- `ADMIN_TOKEN`
- `BETA_MESSAGE`
- `LATEST_VERSION`
- `DOWNLOAD_URL`
- `DOWNLOAD_URL_BASE`

`ANTHROPIC_API_KEY` is no longer referenced — remove it from the deployed
worker's secrets after redeploying.

## Local commands

```bash
cd archive/backend-beta-worker
npm install
npm run dev
npm run deploy
```

## Agent notes

- This directory is isolated from the Swift app build.
- The current macOS app does not consume DMG self-update checks from this worker (Sparkle handles updates) and the historical Anthropic proxy route has been removed.
- If you touch beta-only Swift code in `Sources/Observability/` or `Sources/Beta/BetaConfig.swift`, verify whether the change also requires a backend change here.
- There is currently no local test harness documented for the Worker; review the SQL schema and endpoint contracts directly before refactoring.
