// Transcripted Beta Proxy — Cloudflare Worker
// Token-gated telemetry/log/config endpoints for the beta channel.
// The historical `/v1/messages` route that proxied to Anthropic has been
// removed: the current app on main does not chat with Anthropic via this
// worker, and any leaked beta token used to be enough to bill operator-funded
// LLM spend. ANTHROPIC_API_KEY is no longer read here — rotate it in the
// Cloudflare dashboard if it is still present.

interface Env {
  DB: D1Database;
  ADMIN_TOKEN?: string;
  BETA_MESSAGE?: string;
  LATEST_VERSION?: string;
  DOWNLOAD_URL?: string;       // Legacy single-URL (unused if DOWNLOAD_URL_BASE is set)
  DOWNLOAD_URL_BASE?: string;  // Per-user: base + /Transcripted-{Name}.dmg
}

interface User {
  id: number;
  token: string;
  name: string;
  active: number;
  max_drafts_per_day: number;
}

// Extract bearer token from Authorization header
function extractToken(request: Request): string | null {
  const auth = request.headers.get("Authorization") ?? "";
  if (auth.startsWith("Bearer ")) {
    return auth.slice(7);
  }
  return null;
}

// Validate token against D1 users table
async function validateToken(db: D1Database, token: string): Promise<User | null> {
  const result = await db
    .prepare("SELECT * FROM users WHERE token = ? AND active = 1")
    .bind(token)
    .first<User>();
  return result;
}

// POST /events — Log telemetry events from the app
async function handleEvents(
  request: Request,
  env: Env,
  user: User
): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  // Limit payload size to prevent abuse
  const payloadStr = body.payload ? JSON.stringify(body.payload) : null;
  if (payloadStr && payloadStr.length > 4096) {
    return new Response("Payload too large", { status: 413 });
  }

  await env.DB.prepare(
    "INSERT INTO events (user_id, event_type, source_app, payload) VALUES (?, ?, ?, ?)"
  )
    .bind(
      user.id,
      (body.event_type as string) ?? "unknown",
      (body.source_app as string) ?? null,
      payloadStr
    )
    .run();

  return new Response(JSON.stringify({ ok: true }), {
    headers: { "Content-Type": "application/json" },
  });
}

// POST /logs — Receive debug log lines from the app
async function handleLogs(
  request: Request,
  env: Env,
  user: User
): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  await env.DB.prepare(
    "INSERT INTO logs (user_id, log_lines, event_lines) VALUES (?, ?, ?)"
  )
    .bind(
      user.id,
      (body.log_lines as string) ?? null,
      (body.event_lines as string) ?? null
    )
    .run();

  return new Response(JSON.stringify({ ok: true }), {
    headers: { "Content-Type": "application/json" },
  });
}

// GET /config — Return configuration for this beta user
async function handleConfig(
  env: Env,
  user: User
): Promise<Response> {
  // Per-user download URL: base + /Transcripted-{Name}.dmg
  const downloadUrl = env.DOWNLOAD_URL_BASE
    ? `${env.DOWNLOAD_URL_BASE}/Transcripted-${user.name}.dmg`
    : env.DOWNLOAD_URL ?? null;

  return new Response(
    JSON.stringify({
      active: user.active === 1,
      message: env.BETA_MESSAGE ?? null,
      max_drafts_per_day: user.max_drafts_per_day,
      min_version: "1.0.0",
      latest_version: env.LATEST_VERSION ?? null,
      download_url: downloadUrl,
    }),
    { headers: { "Content-Type": "application/json" } }
  );
}

// GET /admin/usage — Usage summary (admin-only)
async function handleAdminUsage(
  request: Request,
  env: Env
): Promise<Response> {
  const token = extractToken(request);
  if (!env.ADMIN_TOKEN || token !== env.ADMIN_TOKEN) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Per-user API usage totals
  const usage = await env.DB.prepare(`
    SELECT u.name, u.token, u.active,
      COUNT(a.id) as total_calls,
      SUM(a.input_tokens) as total_input_tokens,
      SUM(a.output_tokens) as total_output_tokens
    FROM users u
    LEFT JOIN api_calls a ON a.user_id = u.id
    GROUP BY u.id
    ORDER BY total_calls DESC
  `).all();

  // Per-user event breakdown (drafts accepted, cancelled, dictations, etc.)
  const events = await env.DB.prepare(`
    SELECT u.name, e.event_type, COUNT(*) as count
    FROM events e
    JOIN users u ON u.id = e.user_id
    GROUP BY u.name, e.event_type
    ORDER BY u.name, count DESC
  `).all();

  // Per-user usage stats (computed from event payloads)
  const userStats = await env.DB.prepare(`
    SELECT u.name,
      COUNT(CASE WHEN e.event_type = 'draft_accepted' THEN 1 END) as drafts_accepted,
      COUNT(CASE WHEN e.event_type = 'draft_cancelled' THEN 1 END) as drafts_cancelled,
      COUNT(CASE WHEN e.event_type = 'dictation_completed' THEN 1 END) as dictations,
      COUNT(CASE WHEN e.event_type = 'dictation_cancelled' THEN 1 END) as dictations_cancelled,
      COUNT(CASE WHEN e.event_type = 'app_launched' THEN 1 END) as app_launches,
      SUM(CASE WHEN e.event_type = 'draft_accepted' THEN CAST(json_extract(e.payload, '$.duration_s') AS INTEGER) ELSE 0 END) as total_draft_time_s,
      SUM(CASE WHEN e.event_type = 'dictation_completed' THEN CAST(json_extract(e.payload, '$.duration_s') AS INTEGER) ELSE 0 END) as total_dictation_time_s,
      SUM(CASE WHEN e.event_type = 'draft_accepted' THEN CAST(json_extract(e.payload, '$.accepted_chars') AS INTEGER) ELSE 0 END) as total_chars_drafted,
      SUM(CASE WHEN e.event_type = 'dictation_completed' THEN CAST(json_extract(e.payload, '$.chars') AS INTEGER) ELSE 0 END) as total_chars_dictated,
      COUNT(CASE WHEN e.event_type = 'draft_accepted' AND json_extract(e.payload, '$.was_edited') = 1 THEN 1 END) as drafts_edited
    FROM users u
    LEFT JOIN events e ON e.user_id = u.id
    GROUP BY u.id
    ORDER BY drafts_accepted DESC
  `).all();

  // Daily activity (last 7 days)
  const dailyActivity = await env.DB.prepare(`
    SELECT date(e.created_at) as day,
      u.name,
      COUNT(CASE WHEN e.event_type = 'draft_accepted' THEN 1 END) as drafts,
      COUNT(CASE WHEN e.event_type = 'dictation_completed' THEN 1 END) as dictations
    FROM events e
    JOIN users u ON u.id = e.user_id
    WHERE e.created_at >= datetime('now', '-7 days')
    GROUP BY day, u.name
    ORDER BY day DESC, u.name
  `).all();

  // Most used apps
  const topApps = await env.DB.prepare(`
    SELECT u.name, e.source_app, COUNT(*) as count
    FROM events e
    JOIN users u ON u.id = e.user_id
    WHERE e.source_app IS NOT NULL
    GROUP BY u.name, e.source_app
    ORDER BY count DESC
    LIMIT 20
  `).all();

  // Recent logs (last 20, full content)
  const recentLogs = await env.DB.prepare(`
    SELECT u.name, l.created_at, l.log_lines
    FROM logs l
    JOIN users u ON u.id = l.user_id
    WHERE l.log_lines IS NOT NULL
    ORDER BY l.created_at DESC
    LIMIT 20
  `).all();

  // Recent structured events from EventReporter (shipped via event_lines)
  const recentEvents = await env.DB.prepare(`
    SELECT u.name, l.created_at, l.event_lines
    FROM logs l
    JOIN users u ON u.id = l.user_id
    WHERE l.event_lines IS NOT NULL
    ORDER BY l.created_at DESC
    LIMIT 20
  `).all();

  return new Response(
    JSON.stringify({
      usage: usage.results,
      events: events.results,
      user_stats: userStats.results,
      daily_activity: dailyActivity.results,
      top_apps: topApps.results,
      recent_logs: recentLogs.results,
      recent_events: recentEvents.results,
    }),
    { headers: { "Content-Type": "application/json" } }
  );
}

// Main request handler
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    // CORS preflight — reject browser requests (native URLSession clients don't send preflight)
    if (method === "OPTIONS") {
      return new Response(null, { status: 204 });
    }

    // Admin endpoint (separate auth)
    if (method === "GET" && path === "/admin/usage") {
      return handleAdminUsage(request, env);
    }

    // Health check
    if (method === "GET" && path === "/") {
      return new Response(JSON.stringify({ status: "ok", service: "transcripted-proxy" }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // All other endpoints require a valid beta token
    const token = extractToken(request);
    if (!token) {
      return new Response("Missing Authorization header", { status: 401 });
    }

    const user = await validateToken(env.DB, token);
    if (!user) {
      return new Response("Invalid or revoked beta token", { status: 401 });
    }

    // Route to handlers
    if (method === "POST" && path === "/events") {
      return handleEvents(request, env, user);
    }
    if (method === "POST" && path === "/logs") {
      return handleLogs(request, env, user);
    }
    if (method === "GET" && path === "/config") {
      return handleConfig(env, user);
    }

    return new Response("Not found", { status: 404 });
  },
};
