-- Draft Beta — Useful D1 Queries
-- Run: wrangler d1 execute draft-beta-db --command="<query>"

-- Usage per user (last 7 days)
SELECT u.name, COUNT(*) as drafts,
    SUM(a.input_tokens + a.output_tokens) as total_tokens
FROM api_calls a
JOIN users u ON a.user_id = u.id
WHERE a.created_at > datetime('now', '-7 days')
GROUP BY u.name ORDER BY drafts DESC;

-- Daily active users
SELECT DATE(a.created_at) as day, COUNT(DISTINCT a.user_id) as dau
FROM api_calls a
GROUP BY day ORDER BY day DESC LIMIT 14;

-- Acceptance rate from events
SELECT u.name,
    SUM(CASE WHEN e.event_type = 'draft_accepted' THEN 1 ELSE 0 END) as accepted,
    SUM(CASE WHEN e.event_type = 'draft_cancelled' THEN 1 ELSE 0 END) as cancelled
FROM events e
JOIN users u ON u.id = e.user_id
GROUP BY u.name;

-- Token usage and cost estimate (Haiku pricing: $0.25/MTok in, $1.25/MTok out)
SELECT u.name,
    SUM(a.input_tokens) as input_tokens,
    SUM(a.output_tokens) as output_tokens,
    ROUND(SUM(a.input_tokens) * 0.00000025 + SUM(a.output_tokens) * 0.00000125, 4) as est_cost_usd
FROM api_calls a
JOIN users u ON a.user_id = u.id
GROUP BY u.name;

-- Recent errors from logs
SELECT u.name, l.log_lines, l.created_at
FROM logs l
JOIN users u ON u.id = l.user_id
ORDER BY l.created_at DESC LIMIT 20;

-- All events in last 24 hours
SELECT u.name, e.event_type, e.source_app, e.created_at
FROM events e
JOIN users u ON u.id = e.user_id
WHERE e.created_at > datetime('now', '-1 day')
ORDER BY e.created_at DESC;
