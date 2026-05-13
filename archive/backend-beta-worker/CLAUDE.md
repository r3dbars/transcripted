# Beta Backend

## What This Directory Owns

`archive/backend-beta-worker/` is a standalone Cloudflare Worker used for beta/distribution support.

It is not in the Swift compile graph. Local meeting and dictation functionality
on `main` does not depend on this worker.

## Files

- `src/index.ts`
  Main worker entrypoint and request router.
- `wrangler.toml`
  Worker name, compatibility date, env vars, and D1 binding.
- `schema.sql`
  D1 schema for beta users, API calls, events, and uploaded logs.
- `queries.sql`
  Handy operational queries for D1.
- `seed.sql`
  Manual seed data for beta users.
- `package.json`
  Worker dev/deploy scripts.

## Current Endpoints

- `GET /`
  Health check.
- `POST /events`
  Stores structured telemetry events from the app.
- `POST /logs`
  Stores uploaded debug/event log batches.
- `GET /config`
  Returns retained per-user beta config like update message and download URL.
- `GET /admin/usage`
  Admin-token-gated usage summary.

All non-admin endpoints require a bearer token that maps to an active user in
the D1 `users` table.

The historical `POST /v1/messages` route that proxied to Anthropic has been
removed from this source. The current app on `main` does not call Anthropic
through this worker. If the live deployment still serves `/v1/messages`,
redeploy from this archive and rotate `ANTHROPIC_API_KEY` out of the worker's
secrets. The `api_calls` D1 table (see `schema.sql`) becomes dead; drop it at
your leisure.

## Important Reality Check

The app on `main` is local-first; this worker covers beta telemetry/log/config
paths only. The current macOS app on `main` does not consume `/config` for DMG
self-update checks (Sparkle handles updates) — that endpoint remains
backend/beta-ops context.

## Data Model

Primary tables:

- `users`
- `api_calls`
- `events`
- `logs`

The worker stores usage and telemetry metadata, not user meeting transcripts.

## Verification

Typical commands:

```bash
cd archive/backend-beta-worker
npm install
npm run dev
```

For schema changes, also verify the SQL files still match the TypeScript query
shapes in `src/index.ts`.

## When To Update This Doc

Update this file if you change:

- exposed endpoints
- auth/token behavior
- D1 schema
- app/backend contract fields returned by `/config`
- which beta-only Swift code reads this worker
