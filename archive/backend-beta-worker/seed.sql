-- Draft Beta — Seed beta users
-- Run: wrangler d1 execute draft-beta-db --remote --file=seed.sql

INSERT INTO users (token, name) VALUES ('draft-beta-nate', 'Nate');
INSERT INTO users (token, name) VALUES ('draft-beta-josh', 'Josh');

-- Migration: add event_lines column to logs table (for existing D1 instances)
-- Run: wrangler d1 execute draft-beta-db --remote --command "ALTER TABLE logs ADD COLUMN event_lines TEXT;"
