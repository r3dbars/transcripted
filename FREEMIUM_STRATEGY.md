# Murmur Pro: Freemium Strategy & Implementation Plan

## Executive Summary

Transform Murmur from a local transcription app into a freemium SaaS product with AI-enhanced notes and MCP (Model Context Protocol) integration. This document outlines the complete strategy, technical architecture, and 9-week implementation roadmap.

**Target Pricing:** $12/month for Pro tier
**Target Margin:** 99% gross margin
**Break-even:** Month 2 at 100 paying users

---

## Table of Contents

1. [Product Overview](#product-overview)
2. [Market Positioning](#market-positioning)
3. [Technical Architecture](#technical-architecture)
4. [Database Schema](#database-schema)
5. [Authentication Flow](#authentication-flow)
6. [MCP Integration Strategy](#mcp-integration-strategy)
7. [Unit Economics](#unit-economics)
8. [Implementation Roadmap](#implementation-roadmap)
9. [Complete Todo List](#complete-todo-list)
10. [Success Metrics](#success-metrics)
11. [Risk Mitigation](#risk-mitigation)
12. [Privacy & Security](#privacy--security)

---

## Product Overview

### Free Tier
- Unlimited local transcription (with 25/month soft limit)
- Dual audio capture (mic + system audio)
- Markdown output with timestamps
- Local storage only
- Basic transcription quality

### Pro Tier ($12/month)
- Everything in Free, plus:
- **AI-Enhanced Transcripts:**
  - Automatic summaries
  - Action items extraction
  - Topic tagging
  - Key decisions highlighted
  - Questions tracking
  - Custom metadata
- **MCP Integration:**
  - Search all transcripts from Claude Desktop
  - Query meetings: "What did we decide about pricing?"
  - Extract action items: "What are my todos from this week?"
  - Semantic search across all conversations
- Cloud sync and backup
- Unlimited transcriptions
- Priority support

---

## Market Positioning

### Target Audience
1. **Knowledge Workers** - Professionals who have lots of meetings
2. **Remote Teams** - Distributed teams who need meeting records
3. **Consultants** - Need to track client conversations
4. **Researchers** - Interview transcription and analysis
5. **Sales Teams** - Call recording and analysis

### Competitive Advantage
- **Privacy-first:** Local transcription, optional cloud
- **macOS Native:** Built with Swift, not Electron
- **MCP Integration:** Unique feature for Claude Desktop users
- **Price:** $12/month vs $20-30/month for Otter/Fireflies
- **No browser required:** Runs silently in background

### Differentiation Matrix

| Feature | Murmur Pro | Otter.ai | Fireflies | Grain |
|---------|-----------|----------|-----------|-------|
| Price | $12/mo | $20/mo | $18/mo | $29/mo |
| Local Processing | ✅ | ❌ | ❌ | ❌ |
| Privacy-First | ✅ | ❌ | ❌ | ❌ |
| MCP Integration | ✅ | ❌ | ❌ | ❌ |
| macOS Native | ✅ | ❌ | ❌ | ❌ |
| System Audio | ✅ | ⚠️ | ⚠️ | ⚠️ |

---

## Technical Architecture

### Stack Overview

```
┌─────────────────────────────────────────────────────────┐
│                    macOS App (Swift)                     │
│  ┌────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   Audio    │  │ Transcription│  │ Cloud Sync      │  │
│  │  Capture   │→ │   (Local)    │→ │ (Pro Only)      │  │
│  └────────────┘  └─────────────┘  └─────────────────┘  │
│         ↓                                    ↓           │
│  ┌────────────────────────────────┐         ↓           │
│  │   MCP Server (Bundled Node.js) │←────────┘           │
│  └────────────────────────────────┘                     │
└─────────────────────────────────────────────────────────┘
                         ↓
                    HTTPS (JWT)
                         ↓
┌─────────────────────────────────────────────────────────┐
│              Next.js API (Vercel Edge)                   │
│  ┌─────────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐ │
│  │  Auth   │  │ Enhance  │  │ Search  │  │ Webhooks │ │
│  └─────────┘  └──────────┘  └─────────┘  └──────────┘ │
└─────────────────────────────────────────────────────────┘
         ↓              ↓              ↓              ↓
    ┌─────────┐   ┌──────────┐   ┌─────────┐   ┌────────┐
    │Supabase │   │Anthropic │   │ OpenAI  │   │ Stripe │
    │(Postgres│   │ Claude   │   │Embedding│   │        │
    │+pgvector│   │  Haiku   │   │         │   │        │
    └─────────┘   └──────────┘   └─────────┘   └────────┘
```

### Technology Choices

**Backend:**
- **Next.js 14+** - Full-stack React framework
- **Vercel Edge Functions** - Serverless API endpoints (fast, auto-scaling)
- **Supabase** - Postgres + Auth + Storage in one
- **pgvector** - Vector embeddings for semantic search

**AI Services:**
- **Anthropic Claude Haiku** - Fast, cheap enhancement ($0.25 per 1M input tokens)
- **OpenAI text-embedding-3-small** - Vector embeddings ($0.02 per 1M tokens)
- **OpenAI GPT-4o-mini** - Fallback for enhancement if Claude fails

**Payments:**
- **Stripe** - Subscription billing, webhooks, customer portal

**macOS App:**
- **Swift** - Native performance
- **AVFoundation** - Audio capture and processing
- **Speech Framework** - On-device transcription
- **Bundled Node.js** - For MCP server (no npm install required)

---

## Database Schema

### Supabase Tables

```sql
-- Users (managed by Supabase Auth)
-- We'll reference auth.users(id) for user_id

-- Licenses: Track Pro subscriptions
CREATE TABLE licenses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  stripe_customer_id TEXT UNIQUE,
  stripe_subscription_id TEXT UNIQUE,
  status TEXT CHECK (status IN ('active', 'canceled', 'past_due', 'trialing')),
  current_period_start TIMESTAMP WITH TIME ZONE,
  current_period_end TIMESTAMP WITH TIME ZONE,
  cancel_at_period_end BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE INDEX idx_licenses_user_id ON licenses(user_id);
CREATE INDEX idx_licenses_stripe_customer ON licenses(stripe_customer_id);

-- Row Level Security
ALTER TABLE licenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own license" ON licenses
  FOR SELECT USING (auth.uid() = user_id);

-- Transcripts: Store enhanced transcripts
CREATE TABLE transcripts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  original_content TEXT NOT NULL,  -- Raw transcript from app
  enhanced_content TEXT,            -- AI-enhanced version
  metadata JSONB,                   -- {summary, action_items, topics, tags, decisions, questions}
  duration_seconds INTEGER,
  recorded_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE INDEX idx_transcripts_user_id ON transcripts(user_id);
CREATE INDEX idx_transcripts_recorded_at ON transcripts(recorded_at DESC);
CREATE INDEX idx_transcripts_metadata ON transcripts USING gin(metadata);

-- Row Level Security
ALTER TABLE transcripts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own transcripts" ON transcripts
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own transcripts" ON transcripts
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own transcripts" ON transcripts
  FOR UPDATE USING (auth.uid() = user_id);

-- Embeddings: Vector search
CREATE TABLE embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transcript_id UUID REFERENCES transcripts(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  chunk_text TEXT NOT NULL,              -- Text chunk for context
  chunk_index INTEGER NOT NULL,          -- Order in transcript
  embedding vector(1536),                -- OpenAI text-embedding-3-small
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE INDEX idx_embeddings_transcript ON embeddings(transcript_id);
CREATE INDEX idx_embeddings_user ON embeddings(user_id);
CREATE INDEX idx_embeddings_vector ON embeddings USING ivfflat (embedding vector_cosine_ops);

-- Row Level Security
ALTER TABLE embeddings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own embeddings" ON embeddings
  FOR SELECT USING (auth.uid() = user_id);

-- Webhook Events: Prevent duplicate processing
CREATE TABLE webhook_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_event_id TEXT UNIQUE NOT NULL,
  event_type TEXT NOT NULL,
  processed_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE INDEX idx_webhook_events_stripe ON webhook_events(stripe_event_id);

-- Analytics Events: Track usage
CREATE TABLE analytics_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  event_name TEXT NOT NULL,
  event_data JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE INDEX idx_analytics_user ON analytics_events(user_id);
CREATE INDEX idx_analytics_event ON analytics_events(event_name);
CREATE INDEX idx_analytics_created ON analytics_events(created_at DESC);

-- Row Level Security
ALTER TABLE analytics_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can insert own events" ON analytics_events
  FOR INSERT WITH CHECK (auth.uid() = user_id);
```

### Vector Search Function

```sql
-- Search transcripts by semantic similarity
CREATE OR REPLACE FUNCTION search_transcripts(
  query_embedding vector(1536),
  match_threshold float,
  match_count int,
  filter_user_id uuid
)
RETURNS TABLE (
  transcript_id uuid,
  chunk_text text,
  similarity float,
  transcript_title text,
  recorded_at timestamp with time zone
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    e.transcript_id,
    e.chunk_text,
    1 - (e.embedding <=> query_embedding) as similarity,
    t.title,
    t.recorded_at
  FROM embeddings e
  JOIN transcripts t ON t.id = e.transcript_id
  WHERE e.user_id = filter_user_id
    AND 1 - (e.embedding <=> query_embedding) > match_threshold
  ORDER BY e.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;
```

---

## Authentication Flow

### Design: Passwordless with JWT

**Goal:** No in-app account creation. User remains anonymous until they upgrade.

### Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ 1. User opens app (first time)                              │
│    → Generate anonymous UUID                                │
│    → Store in UserDefaults                                  │
│    → No account, no email, 100% local                       │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. User clicks "Upgrade to Pro"                             │
│    → Open Stripe checkout with UUID as client_reference_id  │
│    → User enters email + payment info                       │
│    → Stripe redirects to success page                       │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. Stripe webhook fires (subscription.created)              │
│    → Create Supabase auth user with email                   │
│    → Create license record with stripe_customer_id          │
│    → Link license to user_id                                │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. App polls /api/auth/validate every 2 seconds             │
│    → Send UUID to validate endpoint                         │
│    → Backend finds license by stripe_customer_id            │
│    → Returns JWT token + isPro status                       │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. App stores JWT token in Keychain                         │
│    → All future API calls use JWT in Authorization header   │
│    → Token refresh every 7 days                             │
│    → MCP server uses same token                             │
└─────────────────────────────────────────────────────────────┘
```

### API Endpoints

**POST /api/auth/create-session**
```typescript
// Called by Stripe webhook after payment
// Creates Supabase user and returns JWT
{
  email: string;           // From Stripe
  stripeCustomerId: string;
  stripeSubscriptionId: string;
}
→ Returns: { userId, token, expiresAt }
```

**POST /api/auth/validate**
```typescript
// Called by app to check Pro status
{
  userId?: string;  // Optional (for existing users)
  email?: string;   // Optional (if user knows their email)
}
→ Returns: { isPro, expiresAt, token? }
```

**POST /api/auth/refresh**
```typescript
// Called by app to refresh expired token
{
  refreshToken: string;
}
→ Returns: { token, expiresAt }
```

### Security Considerations

1. **JWT Tokens:**
   - Short-lived access tokens (1 hour)
   - Long-lived refresh tokens (30 days)
   - Stored in macOS Keychain (not UserDefaults)

2. **Rate Limiting:**
   - 10 validation requests per minute per IP
   - Prevent brute-force attacks

3. **Token Refresh:**
   - Automatic refresh 5 minutes before expiry
   - Graceful degradation if refresh fails

---

## MCP Integration Strategy

### What is MCP?

Model Context Protocol - Allows Claude Desktop to access external data sources. Users can query their transcripts directly from Claude.

### Architecture

```
┌──────────────────────────────────────────────────────────┐
│              Claude Desktop (by Anthropic)                │
│                                                           │
│  User: "What did we decide about pricing?"               │
│         ↓                                                 │
│  Claude invokes: search_meetings("pricing decisions")    │
└──────────────────────────────────────────────────────────┘
                          ↓
                   stdio protocol
                          ↓
┌──────────────────────────────────────────────────────────┐
│         MCP Server (Bundled in Murmur.app)                │
│  Location: Murmur.app/Contents/Resources/mcp-server/     │
│                                                           │
│  Tools:                                                   │
│  - search_meetings(query, limit)                         │
│  - list_action_items(days)                               │
│  - get_summary(transcript_id)                            │
└──────────────────────────────────────────────────────────┘
                          ↓
                    HTTPS (JWT auth)
                          ↓
┌──────────────────────────────────────────────────────────┐
│            Next.js API (Vercel)                          │
│  /api/transcripts/search                                 │
│  /api/transcripts/action-items                           │
│  /api/transcripts/{id}                                   │
└──────────────────────────────────────────────────────────┘
                          ↓
┌──────────────────────────────────────────────────────────┐
│         Supabase (Postgres + pgvector)                   │
│  - Vector search across embeddings                       │
│  - Filter by user_id (RLS)                               │
│  - Return relevant transcript chunks                     │
└──────────────────────────────────────────────────────────┘
```

### Bundling Strategy

**Problem:** Requiring users to run `npm install` is terrible UX.

**Solution:** Bundle Node.js binary in the app.

```
Murmur.app/
└── Contents/
    ├── MacOS/
    │   └── Murmur
    └── Resources/
        └── mcp-server/
            ├── node              # Node.js v20 arm64 binary (30MB)
            ├── server.js         # Compiled MCP server
            ├── package.json
            └── config.json       # Generated at runtime
```

### Auto-Configuration

When user activates Pro:
1. App writes `config.json` with userId, authToken, apiURL
2. App writes Claude Desktop config to:
   ```
   ~/Library/Application Support/Claude/claude_desktop_config.json
   ```
3. Config content:
   ```json
   {
     "mcpServers": {
       "murmur": {
         "command": "/Applications/Murmur.app/Contents/Resources/mcp-server/node",
         "args": ["/Applications/Murmur.app/Contents/Resources/mcp-server/server.js"]
       }
     }
   }
   ```
4. App launches MCP server as subprocess on startup (Pro only)
5. Server stays running in background, communicates via stdio

### MCP Tools

**search_meetings**
```typescript
{
  name: "search_meetings",
  description: "Search across all your meeting transcripts using semantic search",
  inputSchema: {
    type: "object",
    properties: {
      query: { type: "string", description: "Search query (e.g., 'pricing decisions')" },
      limit: { type: "number", default: 5, description: "Max results" }
    },
    required: ["query"]
  }
}
```

**list_action_items**
```typescript
{
  name: "list_action_items",
  description: "Get all action items from recent meetings",
  inputSchema: {
    type: "object",
    properties: {
      days: { type: "number", default: 7, description: "Look back N days" }
    }
  }
}
```

**get_summary**
```typescript
{
  name: "get_summary",
  description: "Get detailed summary of a specific meeting",
  inputSchema: {
    type: "object",
    properties: {
      transcript_id: { type: "string", description: "Transcript UUID" }
    },
    required: ["transcript_id"]
  }
}
```

### Rate Limiting

- 10 search queries per minute (prevent abuse)
- 100 queries per day per user
- Cached query embeddings (10-minute TTL)

---

## Unit Economics

### Cost per Transcript (Pro User)

```
AI Enhancement (Claude Haiku):
- Average transcript: 5,000 tokens
- Input cost: $0.25 per 1M tokens
- Cost per transcript: $0.00125

Embeddings (OpenAI):
- Text-embedding-3-small: $0.02 per 1M tokens
- Average: 5,000 tokens → 10 chunks × 500 tokens
- Cost per transcript: $0.0001

Database (Supabase):
- Free tier: 500MB database, 1GB bandwidth
- Pro tier: $25/month for 8GB database (100k transcripts)
- Cost per transcript: ~$0.00025

Hosting (Vercel):
- Free tier: 100GB bandwidth, 100GB-hours compute
- Pro tier: $20/month for 1TB bandwidth
- Cost per transcript: ~$0.0002

Total Cost per Transcript: $0.00195
```

### Revenue Model

```
Free Users (with 25/month limit):
- Cost: $0 (100% local)
- Revenue: $0
- Purpose: Lead generation

Pro Users ($12/month):
- Typical usage: 60 transcripts/month
- Cost: 60 × $0.00195 = $0.117
- Revenue: $12.00
- Gross profit: $11.88
- Gross margin: 99%
```

### Scaling Economics (Year 1)

| Month | Users | Paying | MRR | Costs | Profit | Margin |
|-------|-------|--------|-----|-------|--------|--------|
| 1 | 100 | 5 | $60 | $100 | -$40 | - |
| 2 | 250 | 13 | $156 | $120 | $36 | 23% |
| 3 | 500 | 25 | $300 | $140 | $160 | 53% |
| 6 | 2,000 | 100 | $1,200 | $200 | $1,000 | 83% |
| 12 | 10,000 | 500 | $6,000 | $500 | $5,500 | 92% |

**Assumptions:**
- 5% conversion rate (free → paid)
- $25/month Supabase, $20/month Vercel, $30/month misc
- Linear user growth (conservative)

### Break-Even Analysis

**Fixed Costs:** ~$75/month (Supabase $25 + Vercel $20 + Domain/Email $10 + Misc $20)

**Variable Costs:** $0.00195 per transcript

**Break-even:** 7 paying users @ 60 transcripts/month = $84 MRR

**Target:** 100 paying users = $1,200 MRR, $1,107 profit/month

---

## Implementation Roadmap

### Phase 1: Backend Infrastructure (Week 1-2)

**Week 1: Supabase + API Foundation**
- Set up Supabase project
- Create database schema (licenses, transcripts, embeddings, webhook_events, analytics_events)
- Enable pgvector extension
- Configure Row Level Security policies
- Initialize Next.js project
- Deploy to Vercel
- Set up environment variables

**Week 2: Core Endpoints**
- Implement `/api/auth/validate` - License validation
- Implement `/api/auth/create-session` - User creation
- Implement `/api/auth/refresh` - Token refresh
- Implement `/api/transcripts/upload` - Upload transcript
- Implement `/api/transcripts/enhance` - AI enhancement (Claude Haiku)
- Implement `/api/transcripts/search` - Vector search
- Implement `/api/webhooks/stripe` - Webhook handler with idempotency
- Test enhancement pipeline end-to-end

**Deliverable:** Fully functional API with AI enhancement and search

---

### Phase 2: macOS App Integration (Week 3-4)

**Week 3: License Management**
- Create `Models/License.swift` - License model and manager
- Create `Services/CloudSync.swift` - Upload transcripts to API
- Create `Services/TranscriptCounter.swift` - Track 25/month limit
- Create `Services/Analytics.swift` - Event tracking
- Modify `MurmurApp.swift`:
  - Initialize LicenseManager, CloudSync, TranscriptCounter
  - Validate license on startup
  - Add "Upgrade to Pro" menu item
  - Add "Send Feedback" menu item
- Modify `TranscriptSaver.swift`:
  - Upload to cloud after local save (Pro only)
  - Increment transcript counter
  - Show upgrade prompt when nearing limit

**Week 4: UI & Upgrade Flow**
- Create `UI/UpgradeView.swift` - Pro upgrade page
- Create `UI/OnboardingView.swift` - First-launch tutorial
- Modify `UI/Settings.swift`:
  - Add Pro status banner
  - Add "Upgrade to Pro" button (free users)
  - Add Pro features section (cloud sync toggle, MCP toggle)
  - Show transcript counter for free users
- Implement passwordless auth flow:
  - Generate UUID for new users
  - Open Stripe checkout in browser
  - Poll for license activation
  - Store JWT token in Keychain
- Test upgrade flow end-to-end

**Deliverable:** App with Pro tier UI and working upgrade flow

---

### Phase 3: MCP Server (Week 5-6)

**Week 5: Build MCP Server**
- Initialize Node.js project (`murmur-mcp/`)
- Install `@modelcontextprotocol/sdk`
- Create `src/index.ts` - Main MCP server
- Create `src/tools/search.ts` - search_meetings tool
- Create `src/tools/actions.ts` - list_action_items tool
- Create `src/tools/summary.ts` - get_summary tool
- Create `src/api/client.ts` - API client (calls Next.js backend)
- Build and test standalone
- Add rate limiting (10 queries/minute)

**Week 6: Bundle & Auto-Configure**
- Download Node.js v20 arm64 binary (30MB)
- Add to Xcode: `Resources/mcp-server/node`
- Add compiled server: `Resources/mcp-server/server.js`
- Create `Services/MCPServerManager.swift`:
  - `startMCPServer()` - Launch Node as subprocess
  - `stopMCPServer()` - Clean shutdown
  - `configureClaudeDesktop()` - Auto-write config
  - Export config.json with userId, authToken, apiURL
- Auto-start MCP server on app launch (Pro only)
- Test search from Claude Desktop
- Test graceful degradation (no internet, expired license)

**Deliverable:** Fully functional MCP integration

---

### Phase 4: Payments & Launch Prep (Week 7-8)

**Week 7: Stripe Production & Testing**
- Switch to live Stripe API keys
- Create production price ($12/month)
- Update checkout flow with production price ID
- Configure production webhook endpoint
- Test live payment with real card
- Implement email automation (Resend/Postmark):
  - Welcome email on signup
  - Payment confirmation email
  - Setup instructions email
- Comprehensive testing with 5 beta users:
  - Fresh install → first recording
  - Free tier limit enforcement
  - Upgrade flow → payment → activation
  - Cloud upload → AI enhancement
  - MCP search from Claude Desktop
  - Network offline scenarios
  - License expiry handling
- Collect feedback and fix bugs

**Week 8: Final Features**
- Create `/pages/feedback.tsx` - Feedback form
- Add "Send Feedback" button to menu bar
- Create privacy policy page
- Create terms of service page
- Add analytics tracking (key events)
- Set up error monitoring (Sentry or similar)
- Create demo video (2-3 minutes)
- Write launch blog post
- Prepare social media posts
- Code signing with Developer ID certificate
- Notarize app with Apple

**Deliverable:** Production-ready app with all features

---

### Week 9: Launch

**Launch Checklist:**
- [ ] All beta bugs fixed
- [ ] Code signed and notarized
- [ ] DMG created and tested
- [ ] Landing page live
- [ ] Demo video uploaded
- [ ] Blog post ready
- [ ] Social media posts scheduled
- [ ] Email service configured
- [ ] Analytics configured
- [ ] Error monitoring configured
- [ ] Support email set up (hello@yourapp.com)

**Launch Day:**
1. Post on Hacker News (Show HN: Privacy-first meeting transcription for Mac)
2. Post in r/macapps
3. Post in r/productivity
4. Post in r/ObsidianMD (if Obsidian integration)
5. Share on Twitter/X
6. Email existing beta users (if any)
7. Post in relevant Slack/Discord communities
8. Optional: Submit to Product Hunt

**Post-Launch (Week 10+):**
- Monitor error logs daily
- Respond to support emails within 24 hours
- Track key metrics (downloads, conversions, MRR, churn)
- Collect user feedback
- Plan first update based on feedback
- Weekly: Review analytics and optimize
- Monthly: Financial review (costs vs revenue)

---

## Complete Todo List

### Pre-Development Setup
- [ ] Join Apple Developer Program ($99/year)
- [ ] Create Stripe account
- [ ] Create Supabase account
- [ ] Create Vercel account
- [ ] Register domain name
- [ ] Set up email service (Resend/Postmark)

### Phase 1: Backend Infrastructure (Week 1-2)

#### Supabase Setup
- [ ] Create new Supabase project
- [ ] Enable pgvector extension
- [ ] Create `licenses` table
- [ ] Create `transcripts` table
- [ ] Create `embeddings` table
- [ ] Create `webhook_events` table
- [ ] Create `analytics_events` table
- [ ] Configure RLS policies
- [ ] Create `search_transcripts` SQL function

#### Next.js API
- [ ] Initialize Next.js project
- [ ] Install dependencies (Supabase, Anthropic, OpenAI, Stripe)
- [ ] Set up environment variables
- [ ] Create `/api/auth/validate.ts`
- [ ] Create `/api/auth/create-session.ts`
- [ ] Create `/api/auth/refresh.ts`
- [ ] Create `/api/transcripts/upload.ts`
- [ ] Create `/api/transcripts/enhance.ts`
- [ ] Create `/api/transcripts/search.ts`
- [ ] Create `/api/transcripts/action-items.ts`
- [ ] Create `/api/webhooks/stripe.ts`
- [ ] Create `/api/analytics.ts`
- [ ] Create `/api/feedback.ts`

#### Stripe Integration
- [ ] Create "Murmur Pro" product
- [ ] Copy Price ID
- [ ] Create `/pages/checkout.tsx`
- [ ] Create `/api/checkout/create-session.ts`
- [ ] Create `/pages/success.tsx`
- [ ] Create `/pages/cancel.tsx`
- [ ] Set up webhook in Stripe dashboard
- [ ] Test webhook with Stripe CLI

#### Testing
- [ ] Test auth flow
- [ ] Test enhancement with sample transcript
- [ ] Test vector search
- [ ] Test webhook events
- [ ] Deploy to Vercel production

### Phase 2: macOS App Integration (Week 3-4)

#### New Swift Files
- [ ] Create `Models/License.swift`
- [ ] Create `Services/CloudSync.swift`
- [ ] Create `Services/TranscriptCounter.swift`
- [ ] Create `Services/Analytics.swift`
- [ ] Create `UI/UpgradeView.swift`
- [ ] Create `UI/OnboardingView.swift`

#### Modify Existing Files
- [ ] Update `Settings.swift` (Pro status, upgrade button)
- [ ] Update `MurmurApp.swift` (LicenseManager, CloudSync, menu items)
- [ ] Update `TranscriptSaver.swift` (cloud upload, counter)
- [ ] Update `Audio.swift` (counter check before recording)

#### Authentication Flow
- [ ] Implement passwordless flow
- [ ] Generate UUID for new users
- [ ] Create temporary auth session
- [ ] Poll for license activation
- [ ] Store JWT token in Keychain
- [ ] Implement token refresh

#### Analytics
- [ ] Track `app_opened`
- [ ] Track `recording_started`
- [ ] Track `recording_completed`
- [ ] Track `upgrade_clicked`
- [ ] Track `upgrade_completed`
- [ ] Track `mcp_search_performed`
- [ ] Track `transcript_limit_reached`

#### Testing
- [ ] Test free tier limit (25 transcripts)
- [ ] Test upgrade flow (click → payment → activation)
- [ ] Test cloud upload
- [ ] Test offline mode
- [ ] Test license expiry
- [ ] Test onboarding

### Phase 3: MCP Server (Week 5-6)

#### MCP Server Development
- [ ] Initialize Node.js project (`murmur-mcp/`)
- [ ] Install `@modelcontextprotocol/sdk`
- [ ] Create `src/index.ts`
- [ ] Create `src/tools/search.ts`
- [ ] Create `src/tools/actions.ts`
- [ ] Create `src/tools/summary.ts`
- [ ] Create `src/api/client.ts`
- [ ] Build TypeScript → JavaScript
- [ ] Test standalone

#### Bundle in App
- [ ] Download Node.js v20 arm64 binary
- [ ] Add to Xcode: `Resources/mcp-server/node`
- [ ] Add compiled server: `Resources/mcp-server/server.js`
- [ ] Create `Services/MCPServerManager.swift`
- [ ] Auto-start on app launch (Pro only)
- [ ] Auto-stop on app quit

#### Backend API
- [ ] Add rate limiting to search endpoint
- [ ] Add query embedding cache
- [ ] Test search performance

#### Testing
- [ ] Verify MCP server starts
- [ ] Verify Claude Desktop config
- [ ] Test search from Claude Desktop
- [ ] Test action items query
- [ ] Test offline mode
- [ ] Test expired license

### Phase 4: Payments & Launch (Week 7-8)

#### Stripe Production
- [ ] Switch to live API keys
- [ ] Create production price
- [ ] Update checkout flow
- [ ] Configure production webhook
- [ ] Test live payment

#### Email Automation
- [ ] Set up email service
- [ ] Create welcome email
- [ ] Create payment confirmation email
- [ ] Create setup instructions email

#### Feedback & Support
- [ ] Create `/pages/feedback.tsx`
- [ ] Add "Send Feedback" menu item
- [ ] Set up support email
- [ ] Create privacy policy
- [ ] Create terms of service

#### Week 7 Testing
- [ ] Recruit 5 beta testers
- [ ] Test fresh install → first recording
- [ ] Test free tier limit
- [ ] Test upgrade flow
- [ ] Test cloud upload → AI enhancement
- [ ] Test MCP search
- [ ] Test offline scenarios
- [ ] Test license expiry
- [ ] Collect feedback
- [ ] Fix critical bugs

#### Week 8 Final
- [ ] Fix all beta bugs
- [ ] Code sign with Developer ID
- [ ] Notarize with Apple
- [ ] Create DMG
- [ ] Final QA pass
- [ ] Performance testing

### Week 9: Launch

#### Launch Prep
- [ ] Demo video (2-3 minutes)
- [ ] Launch blog post
- [ ] Social media posts
- [ ] Landing page
- [ ] Analytics configured
- [ ] Error monitoring configured

#### Launch Day
- [ ] Post on Hacker News
- [ ] Post in r/macapps
- [ ] Post in r/productivity
- [ ] Post in r/ObsidianMD
- [ ] Share on Twitter/X
- [ ] Email beta users
- [ ] Post in communities
- [ ] Optional: Product Hunt

#### Post-Launch (Week 10+)
- [ ] Monitor error logs daily
- [ ] Respond to support emails <24h
- [ ] Track metrics (downloads, conversions, MRR)
- [ ] Collect feedback
- [ ] Plan first update
- [ ] Weekly analytics review
- [ ] Monthly financial review

---

## Success Metrics

### Acquisition Metrics
- **Website visitors → downloads** (conversion rate)
  - Target: 10% (1 in 10 visitors download)
- **Downloads → first recording** (activation rate)
  - Target: 60% (6 in 10 complete setup and record)
- **First recording → 2nd recording** (retention)
  - Target: 70% (7 in 10 come back)

### Conversion Metrics
- **Free users → clicked upgrade** (interest rate)
  - Target: 15% (1.5 in 10 show interest)
- **Clicked upgrade → completed payment** (conversion rate)
  - Target: 33% (1 in 3 complete payment)
- **Overall free → paid conversion**
  - Target: 5% (1 in 20 convert to paid)

### Engagement Metrics
- **Transcripts per user per week**
  - Target: 3-5 (regular usage)
- **MCP searches per Pro user**
  - Target: 10+ per week (high engagement)
- **Churn rate**
  - Target: <5% monthly (95% retention)

### Financial Metrics
- **Monthly Recurring Revenue (MRR)**
  - Month 1: $60 (5 users)
  - Month 3: $300 (25 users)
  - Month 6: $1,200 (100 users)
  - Month 12: $6,000 (500 users)
- **Customer Acquisition Cost (CAC)**
  - Organic: $0 (goal for first 100 users)
  - Paid: <$20 (if running ads)
- **Lifetime Value (LTV)**
  - Target: $144 (12 months average retention)
  - LTV:CAC ratio: >7:1
- **Gross Margin**
  - Target: >95% at scale

### Key Performance Indicators (KPIs)

**Daily:**
- New signups
- Upgrade conversions
- Error rate

**Weekly:**
- Active users (recorded at least once)
- Upgrade click-through rate
- Support ticket volume

**Monthly:**
- MRR growth rate
- Churn rate
- Net revenue retention
- Transcript volume (total and per user)

---

## Risk Mitigation

### Technical Risks

**Risk:** AI API costs higher than expected
- **Mitigation:** Set per-user monthly limits (e.g., 100 transcripts/month for Pro)
- **Mitigation:** Use cheaper models for initial enhancement, premium models on-demand
- **Mitigation:** Monitor costs daily, adjust limits if needed

**Risk:** Supabase/Vercel outage
- **Mitigation:** App works offline (local transcription always available)
- **Mitigation:** Queue cloud uploads for retry
- **Mitigation:** Graceful degradation messaging

**Risk:** MCP server crashes or conflicts
- **Mitigation:** Auto-restart on crash
- **Mitigation:** Detailed error logging
- **Mitigation:** Fallback: Manual MCP config instructions

**Risk:** Apple rejects app or notarization fails
- **Mitigation:** Follow Apple guidelines strictly
- **Mitigation:** Distribute via direct download (no Mac App Store required)
- **Mitigation:** Provide instructions for Gatekeeper bypass if needed

### Business Risks

**Risk:** Low conversion rate (<2%)
- **Mitigation:** A/B test upgrade prompts
- **Mitigation:** Add free trial (7 days of Pro)
- **Mitigation:** Conduct user interviews to understand objections

**Risk:** High churn (>10% monthly)
- **Mitigation:** Exit surveys to understand why
- **Mitigation:** Add features based on feedback
- **Mitigation:** Email campaigns for inactive users

**Risk:** Competitors with more features
- **Mitigation:** Focus on privacy and macOS-native UX
- **Mitigation:** Fast iteration based on user feedback
- **Mitigation:** Build moat with MCP integration (unique feature)

**Risk:** Can't reach target users
- **Mitigation:** Launch on multiple channels (HN, Reddit, Twitter)
- **Mitigation:** Build in public, share progress
- **Mitigation:** Partner with productivity influencers

### Legal/Privacy Risks

**Risk:** GDPR/privacy compliance issues
- **Mitigation:** Privacy-first design (local by default)
- **Mitigation:** Clear opt-in for cloud features
- **Mitigation:** Easy data export and deletion
- **Mitigation:** Hire lawyer for privacy policy review ($500-1000)

**Risk:** Stripe disputes/chargebacks
- **Mitigation:** Clear pricing and feature descriptions
- **Mitigation:** Easy cancellation (no dark patterns)
- **Mitigation:** Responsive support for billing issues

---

## Privacy & Security

### Privacy Principles

1. **Local by default** - Free tier is 100% local, no cloud upload
2. **Explicit opt-in** - Pro users must explicitly enable cloud features
3. **User control** - Easy data export, deletion, and account closure
4. **Transparency** - Clear privacy policy explaining what's stored and why
5. **No third-party tracking** - No Google Analytics, Facebook Pixel, etc.

### Data Handling

**What we store (Pro users only):**
- Transcript text (original + enhanced)
- Metadata (summaries, action items, tags)
- Vector embeddings (for search)
- User email (from Stripe, for billing)
- Usage analytics (anonymized event data)

**What we DON'T store:**
- Audio files (deleted after transcription)
- IP addresses (except for rate limiting, 24h retention)
- Browsing behavior
- Device identifiers (beyond user_id)

**Data retention:**
- Transcripts: Until user deletes or cancels subscription
- Analytics: 90 days
- Webhook events: 30 days (for idempotency)
- Deleted data: Purged within 30 days

### Security Measures

1. **Authentication**
   - JWT tokens with short expiry (1 hour)
   - Refresh tokens with 30-day expiry
   - Tokens stored in macOS Keychain (encrypted)

2. **Authorization**
   - Row Level Security (RLS) in Supabase
   - Every query filtered by user_id
   - No shared data between users

3. **API Security**
   - Rate limiting on all endpoints
   - Input validation and sanitization
   - HTTPS only (TLS 1.3)
   - CORS restrictions

4. **Webhook Security**
   - Stripe signature verification
   - Idempotency checks (prevent duplicate processing)
   - IP allowlisting (Stripe webhook IPs only)

5. **Infrastructure**
   - Vercel (SOC 2 compliant)
   - Supabase (SOC 2 compliant)
   - Regular dependency updates
   - Automated security scanning

### Privacy Policy Highlights

**Required sections:**
1. What data we collect and why
2. How we use the data
3. Third-party services (Stripe, Anthropic, OpenAI, Supabase, Vercel)
4. User rights (access, deletion, export)
5. Data retention and deletion policies
6. Contact information for privacy questions
7. Changes to policy (email notification)

**Key commitments:**
- We never sell your data
- We don't train AI models on your transcripts
- You can export all your data anytime
- You can delete your account and all data anytime
- We'll notify you of any breaches within 72 hours

---

## Next Steps

### Immediate Actions (This Week)

1. **Create accounts:**
   - [ ] Stripe
   - [ ] Supabase
   - [ ] Vercel
   - [ ] Email service (Resend/Postmark)

2. **Register domain:**
   - [ ] yourapp.com (or similar)
   - [ ] Set up DNS

3. **Apple Developer Program:**
   - [ ] Join ($99/year)
   - [ ] Request Developer ID certificate

4. **Set up development environment:**
   - [ ] Clone backend starter (Next.js + Supabase)
   - [ ] Configure environment variables
   - [ ] Test deployment to Vercel

### Week 1 Kickoff

1. Create Supabase project
2. Run database schema SQL
3. Initialize Next.js API
4. Deploy to Vercel
5. Test `/api/auth/validate` endpoint

### Communication

- **Progress updates:** Weekly (Friday EOD)
- **Blockers:** Immediate (don't wait)
- **Questions:** Daily standup (async on Slack/Discord)
- **Code reviews:** Before merging to main

---

## Appendix

### Technology Alternatives Considered

**Backend Framework:**
- ✅ Next.js - Chosen for simplicity, Vercel integration
- ❌ Express.js - More code, manual deployment
- ❌ Rails - Slower for API-only, heavier

**Database:**
- ✅ Supabase (Postgres + pgvector) - Chosen for all-in-one solution
- ❌ Pinecone - More expensive, separate DB needed
- ❌ Weaviate - Self-hosted complexity

**AI Provider:**
- ✅ Anthropic Claude Haiku - Best price/performance
- ⚠️ OpenAI GPT-4o-mini - Fallback option
- ❌ Gemini - No Swift SDK, limited API

**Payments:**
- ✅ Stripe - Industry standard, best docs
- ❌ Paddle - Higher fees (10% vs 2.9%)
- ❌ LemonSqueezy - Less mature, fewer features

### Resources

**Documentation:**
- [Next.js Docs](https://nextjs.org/docs)
- [Supabase Docs](https://supabase.com/docs)
- [Stripe Docs](https://stripe.com/docs)
- [Anthropic API](https://docs.anthropic.com)
- [OpenAI API](https://platform.openai.com/docs)
- [MCP Protocol](https://modelcontextprotocol.io)

**Tools:**
- [Stripe CLI](https://stripe.com/docs/stripe-cli) - Test webhooks locally
- [Supabase CLI](https://supabase.com/docs/guides/cli) - Manage database
- [Vercel CLI](https://vercel.com/docs/cli) - Deploy from terminal

**Community:**
- [r/SaaS](https://reddit.com/r/SaaS) - Bootstrapped SaaS discussion
- [Indie Hackers](https://indiehackers.com) - Solo founder community
- [MCP Discord](https://discord.gg/modelcontextprotocol) - MCP developer community

---

## Conclusion

This freemium strategy transforms Murmur from a local tool into a sustainable SaaS business with:

- **99% gross margins** at scale
- **$12/month pricing** (lower than competitors)
- **Unique features** (MCP integration, privacy-first)
- **9-week timeline** to launch
- **Low risk** (organic growth, no ads needed)

The hybrid local/cloud architecture keeps costs near zero for free users while providing massive value for Pro users. The MCP integration is a unique moat that competitors will struggle to replicate.

**Bottom line:** This is a highly executable plan with strong unit economics and a clear path to profitability. Ship it. 🚀

---

**Document Version:** 1.0
**Last Updated:** 2025-10-26
**Author:** Strategy developed with Claude Code
**Status:** Ready for Implementation
