# Transcripted - Product & Business Report

> A comprehensive overview for stakeholders, investors, and team members unfamiliar with the product.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [The Problem We Solve](#the-problem-we-solve)
3. [Product Overview](#product-overview)
4. [Target Audience](#target-audience)
5. [Business Model](#business-model)
6. [Competitive Landscape](#competitive-landscape)
7. [Technical Architecture](#technical-architecture)
8. [Feature Deep Dive](#feature-deep-dive)
9. [User Experience](#user-experience)
10. [Privacy & Security](#privacy--security)
11. [Roadmap & Future Vision](#roadmap--future-vision)
12. [Metrics & Success Criteria](#metrics--success-criteria)
13. [Appendix: Technical Specifications](#appendix-technical-specifications)

---

## Executive Summary

**Transcripted** is a native macOS application that records, transcribes, and organizes voice conversations from meetings and calls. Transcripted uses **Deepgram Nova-3** cloud transcription API for high-accuracy, multichannel transcription with speaker diarization, delivering professional-grade transcripts with minimal latency.

### Key Value Proposition

> "Never miss a word from your meetings. Transcripted captures everything, transcribes it with Deepgram Nova-3, and organizes it beautifully—giving you accurate, speaker-labeled transcripts in seconds."

### At a Glance

| Attribute | Detail |
|-----------|--------|
| **Platform** | macOS 14.2+ (Sonoma and later) |
| **Category** | Productivity / Meeting Tools |
| **Pricing Model** | Freemium with Cloud Sync subscription |
| **Primary Differentiator** | Deepgram Nova-3 cloud transcription with speaker diarization |
| **Development Stage** | Beta / Early Production |
| **Target Launch** | Q1 2025 |

---

## The Problem We Solve

### The Meeting Overload Crisis

Modern knowledge workers spend an average of **23 hours per week in meetings**. Yet:

- **73%** of professionals admit to doing other work during meetings
- **47%** complain meetings are the #1 time-waster at work
- **90%** of people daydream in meetings
- Only **37%** of meetings result in documented action items

### Current Solutions Fall Short

| Existing Solution | Problems |
|-------------------|----------|
| **Manual note-taking** | Distracting, incomplete, inconsistent |
| **Cloud transcription (Otter, Fireflies)** | Privacy concerns, requires internet, subscription fatigue |
| **Meeting recordings** | Large files, no searchable text, time-consuming to review |
| **AI meeting bots** | Intrusive, requires meeting permissions, "bot in the call" stigma |

### The Transcripted Difference

Transcripted operates **invisibly in the background**:

1. **No bot joins your call** — captures system audio directly from your Mac
2. **High-accuracy cloud transcription** — powered by Deepgram Nova-3 with multichannel support and speaker diarization
3. **One-click recording** — start and stop via the floating pill interface
4. **Two-pass AI pipeline** — Gemini 2.5 Pro extracts action items and summaries automatically

---

## Product Overview

### What Transcripted Does

```
┌─────────────────────────────────────────────────────────────────┐
│                      TRANSCRIPTED WORKFLOW                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   🟢 User Clicks Pill      →    🎤 Recording Starts             │
│   (Floating pill UI)             (Mic + System Audio)            │
│                                                                 │
│   🔇 Silence Detected      →    ⏹️ Smart Stop Prompt            │
│   (After 2 minutes)             ("Still recording?")            │
│                                                                 │
│   🎙️ Audio Captured        →    📝 Deepgram Nova-3 Transcription│
│   (Dual-stream WAV)             (Cloud API, speaker diarization)│
│                                                                 │
│   🤖 Gemini 2.5 Pro        →    ✅ Transcript Saved             │
│   (Action items + summary)       (Markdown + timestamps)         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Core Capabilities

1. **Dual-Stream Audio Capture**
   - Records your microphone (what you say)
   - Records system audio (what others say in meetings)
   - Keeps them separate for clear attribution

2. **One-Click Recording via Floating Pill**
   - Minimal always-on-screen pill interface for instant recording
   - Single click to start/stop — no navigation required
   - Visual waveform and timer during active recording

3. **Deepgram Nova-3 Cloud Transcription**
   - High-accuracy transcription via Deepgram Nova-3 cloud API
   - Multichannel support for separate mic and system audio streams
   - Speaker diarization for automatic speaker labeling

4. **Smart Recording Management**
   - Monitors for prolonged silence (2+ minutes)
   - Prompts: "Still recording?" to prevent accidental long recordings
   - Shows real-time duration and audio levels

5. **Professional Transcript Output**
   - Markdown format with YAML metadata
   - Precise timestamps for every segment
   - Speaker attribution (You vs. Others)
   - Ready for search, sharing, or AI summarization

6. **Optional Cloud Synchronization** **Planned — Not Yet Implemented**
   - Sync transcripts across devices
   - Team sharing capabilities
   - Secure JWT authentication

---

## Target Audience

### Primary Personas

#### 1. The Busy Sales Professional
> **"I have 8+ calls a day and can't remember what was promised to whom."**

| Attribute | Detail |
|-----------|--------|
| **Job Title** | Account Executive, SDR, Customer Success Manager |
| **Pain Points** | Forgetting follow-up items, losing deal context, CRM data entry |
| **Use Case** | Record sales calls, reference later for proposals, log to CRM |
| **Value** | Never miss a customer commitment, faster proposal writing |

#### 2. The Remote Team Manager
> **"My team is distributed and I need to stay aligned without attending every meeting."**

| Attribute | Detail |
|-----------|--------|
| **Job Title** | Engineering Manager, Product Manager, Team Lead |
| **Pain Points** | Meeting overload, context switching, keeping up with team decisions |
| **Use Case** | Record standups/1:1s, share transcripts with absent team members |
| **Value** | Async-first culture, documented decisions, reduced meeting fatigue |

#### 3. The Privacy-Conscious Professional
> **"I need transcription but don't want a bot in my calls or my data stored on someone else's servers."**

| Attribute | Detail |
|-----------|--------|
| **Job Title** | Lawyer, Therapist, Healthcare Worker, Executive |
| **Pain Points** | "Bot in the call" stigma, data retention by third parties, compliance concerns |
| **Use Case** | Record consultations discreetly, transcripts stored locally on their Mac |
| **Value** | No meeting bot, local transcript storage, audio deleted after transcription |

#### 4. The Researcher/Interviewer
> **"I conduct user interviews and need accurate, timestamped transcripts."**

| Attribute | Detail |
|-----------|--------|
| **Job Title** | UX Researcher, Journalist, Academic |
| **Pain Points** | Manual transcription is slow, timestamps are hard to track |
| **Use Case** | Record interviews, reference specific moments, quote accurately |
| **Value** | Hours saved on transcription, precise citations |

### Market Size

| Segment | Size | Growth |
|---------|------|--------|
| **Global Meeting Software Market** | $14.1B (2023) | 11.2% CAGR |
| **AI Transcription Market** | $2.8B (2023) | 17.3% CAGR |
| **macOS Active Users** | 100M+ devices | Growing |
| **Remote Workers (US)** | 35% of workforce | Stable |

**Serviceable Addressable Market (SAM)**: ~5M macOS users who regularly attend virtual meetings and would pay for transcription tools.

---

## Business Model

### Revenue Strategy: Freemium + Cloud Subscription

```
┌─────────────────────────────────────────────────────────────────┐
│                        PRICING TIERS                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   🆓 FREE TIER                    💎 PRO TIER ($9.99/mo)        │
│   ────────────────                ─────────────────────         │
│   ✓ Unlimited local recording     ✓ Everything in Free          │
│   ✓ Deepgram Nova-3 transcription ✓ Cloud sync & backup         │
│   ✓ Gemini AI action items        ✓ Search across transcripts   │
│   ✓ Markdown export               ✓ AI-powered summaries*       │
│   ✓ 7-day transcript retention    ✓ Unlimited retention         │
│   ✗ Cloud sync                    ✓ Team sharing*               │
│   ✗ AI summaries                  ✓ Priority support            │
│                                                                 │
│                       🏢 TEAM TIER ($29.99/user/mo)             │
│                       ─────────────────────────────             │
│                       ✓ Everything in Pro                       │
│                       ✓ Shared team workspace                   │
│                       ✓ Admin controls & SSO                    │
│                       ✓ Analytics dashboard                     │
│                       ✓ API access                              │
│                       ✓ Custom retention policies               │
│                                                                 │
│   * Features marked with asterisk are on roadmap                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Revenue Projections (Conservative)

| Metric | Year 1 | Year 2 | Year 3 |
|--------|--------|--------|--------|
| **Free Users** | 10,000 | 40,000 | 100,000 |
| **Pro Conversion Rate** | 5% | 7% | 10% |
| **Pro Subscribers** | 500 | 2,800 | 10,000 |
| **Team Subscribers** | 50 | 300 | 1,000 |
| **Monthly Revenue** | $6,500 | $35,700 | $130,000 |
| **Annual Revenue** | $78,000 | $428,400 | $1,560,000 |

### Monetization Philosophy

1. **Free tier must be genuinely useful** — Core transcription works forever, no artificial limits on quality
2. **Paid tier adds convenience, not necessity** — Cloud sync, search, AI features
3. **No predatory practices** — No "transcription credits," no per-minute charges
4. **Core features available to all** — Deepgram transcription and Gemini AI available on all tiers

### Customer Acquisition Strategy

| Channel | Approach | CAC Target |
|---------|----------|------------|
| **Organic/SEO** | "macOS meeting transcription" content | $0-5 |
| **Product Hunt** | Launch campaign | $0 |
| **Mac App Store** | Featured placement pursuit | 30% revenue share |
| **Word of Mouth** | Referral program (1 month free) | $10 |
| **Content Marketing** | Productivity blogs, YouTube | $15 |
| **Partnerships** | Integrate with note-taking apps (Obsidian, Notion) | $20 |

---

## Competitive Landscape

### Market Map

```
                        PRIVACY
                          ▲
                          │
         Transcripted ●         │
    (Local storage,        │
     No bot, Native Mac)   │
                          │
    ──────────────────────┼──────────────────────► FEATURES
    MINIMAL               │                        MAXIMUM
                          │
                          │    ● Otter.ai
         ● Voice Memos    │    (Cloud, Full-featured)
    (Basic, Local)        │
                          │    ● Fireflies.ai
                          │    (Bot-based, AI-rich)
                          │
                          │    ● Grain
                          │    (Video-focused)
```

### Competitive Analysis

| Competitor | Strengths | Weaknesses | Transcripted Advantage |
|------------|-----------|------------|------------------|
| **Otter.ai** | Full-featured, integrations, AI summaries | Cloud-only, privacy concerns, $16.99/mo | Native Mac app, no bot joins call, Gemini AI pipeline |
| **Fireflies.ai** | Great AI, CRM integrations | Bot joins call (awkward), expensive at scale | Invisible operation, no bot stigma |
| **Grain** | Video clips, collaborative | Video-focused, overkill for audio | Lightweight, audio-optimized |
| **Rev** | Human transcription option | Slow (24hr), expensive ($1.50/min) | Instant, high-accuracy Deepgram Nova-3 |
| **Apple Voice Memos** | Free, built-in | No transcription, basic | Full transcription with timestamps |
| **Descript** | Powerful editing | Complex UI, learning curve, $24/mo | Simple single-purpose tool |

### Competitive Moat

1. **Native Mac Experience** — Built with SwiftUI, integrates with macOS features (Notifications, Keychain, Accessibility)
2. **Deepgram Nova-3 Accuracy** — Industry-leading transcription with multichannel support and speaker diarization
3. **Two-Pass Gemini AI Pipeline** — Automatic action item extraction and summarization via Gemini 2.5 Pro
4. **Dual-Stream Architecture** — Unique capture of both microphone and system audio with attribution

---

## Technical Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        TRANSCRIPTED ARCHITECTURE                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐       │
│  │  Audio.swift│     │SystemAudio  │     │Deepgram     │       │
│  │  (Mic Input)│     │Capture.swift│     │Service.swift│       │
│  └──────┬──────┘     └──────┬──────┘     └──────┬──────┘       │
│         │                   │                   │               │
│         ▼                   ▼                   ▼               │
│  ┌─────────────────────────────────────────────────────┐       │
│  │              FloatingPanelController                 │       │
│  │        (State Management & UI Coordination)          │       │
│  └──────────────────────┬──────────────────────────────┘       │
│                         │                                       │
│         ┌───────────────┼───────────────┐                      │
│         ▼               ▼               ▼                      │
│  ┌───────────┐   ┌───────────┐   ┌───────────┐                 │
│  │Transcriptn│   │Transcript │   │CloudSync  │                 │
│  │.swift     │   │Saver.swift│   │Manager    │                 │
│  │(Deepgram) │   │(Markdown) │   │(Planned)  │                 │
│  └───────────┘   └───────────┘   └───────────┘                 │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │                  SwiftUI Interface                   │       │
│  │   FloatingPanelView  │  SettingsView  │  Onboarding  │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| **Swift + SwiftUI** | Native performance, system integration, future-proof |
| **AVFoundation for mic** | Reliable, well-documented, handles format conversion |
| **CoreAudio for system audio** | Only way to capture system-wide audio on macOS |
| **Deepgram Nova-3 API** | High accuracy, multichannel, speaker diarization |
| **Markdown output** | Universal format, works with any tool, version-controllable |
| **Keychain for auth** | macOS-native secure storage, no custom encryption needed |

### Technology Stack

| Layer | Technology |
|-------|------------|
| **Language** | Swift 5.9+ |
| **UI Framework** | SwiftUI |
| **Audio Capture** | AVFoundation, CoreAudio |
| **Transcription** | Deepgram Nova-3 Cloud API |
| **Storage** | FileManager (local), REST API (cloud) |
| **Authentication** | JWT tokens, Keychain storage |
| **State Management** | Combine, @Published properties |
| **Notifications** | UserNotifications framework |

---

## Feature Deep Dive

### 1. The Floating Panel

The primary interface is a **glassmorphic floating panel** that lives at the edge of your screen.

**States:**

| State | Appearance | Triggers |
|-------|------------|----------|
| **Docked/Idle** | Thin dark pill (8px), nearly invisible | Default state |
| **Docked/Recording** | Expanded pill (36px) with waveform + timer | During recording |
| **Expanded** | Full panel with all controls | Mouse hover |
| **Attention Prompt** | Overlay with action buttons | Silence detected |

**Design Philosophy:**
- **Invisible when not needed** — Stays out of your way during work
- **Glanceable status** — Recording state visible at a glance
- **One-click actions** — Start/stop recording without navigation

### 2. Two-Pass Gemini AI Pipeline

After transcription completes, Transcripted runs a two-pass AI analysis using Gemini 2.5 Pro:

| Pass | Purpose | Output |
|------|---------|--------|
| **Pass 1** | Extract action items, decisions, and key topics | Structured action item list |
| **Pass 2** | Generate summary and highlight important moments | Executive summary with timestamps |

**Behavior:**
1. Transcription completes via Deepgram Nova-3
2. First Gemini pass extracts action items and decisions
3. Second Gemini pass generates summary
4. Results embedded in transcript Markdown file
5. Automatic retry on failure with exponential backoff

### 3. Dual-Stream Recording

Captures two separate audio streams:

```
┌────────────────────┐          ┌────────────────────┐
│   MICROPHONE       │          │   SYSTEM AUDIO     │
│   (Your Voice)     │          │   (Meeting Audio)  │
├────────────────────┤          ├────────────────────┤
│ AVAudioEngine      │          │ AudioHardware      │
│ Input Node Tap     │          │ ProcessTap         │
│ 48kHz, 32-bit      │          │ Native Format      │
└─────────┬──────────┘          └─────────┬──────────┘
          │                               │
          ▼                               ▼
┌────────────────────┐          ┌────────────────────┐
│ meeting_mic.wav    │          │ meeting_system.wav │
└────────────────────┘          └────────────────────┘
          │                               │
          └───────────┬───────────────────┘
                      ▼
          ┌────────────────────┐
          │   TRANSCRIPTION    │
          │   (Merged Timeline)│
          └────────────────────┘
```

### 4. Transcription Pipeline

```
Audio File (WAV)
      │
      ▼
┌─────────────────────────────┐
│  Upload to Deepgram Nova-3  │  (Cloud API, multichannel)
│  with speaker diarization   │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Receive transcript with    │  (Speaker labels + timestamps)
│  word-level timestamps      │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Group into sentences       │  (Punctuation + pause detection)
│  with speaker attribution   │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Gemini 2.5 Pro Pass 1      │  (Action items + decisions)
│  Gemini 2.5 Pro Pass 2      │  (Summary generation)
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Output: Markdown file      │
│  with YAML frontmatter      │
└─────────────────────────────┘
```

### 5. Silence Detection

Monitors audio levels during recording:

| Metric | Value |
|--------|-------|
| **Silence Threshold** | 0.02 (normalized amplitude) |
| **Alert Trigger** | 2 minutes continuous silence |
| **Prompt Message** | "Still recording? 2min silence detected" |
| **Auto-behavior** | Prompt only (no auto-stop) |

**Why This Matters:**
- Prevents 3-hour "recordings" of empty room
- Saves storage space and processing time
- Gentle reminder, not aggressive interruption

### 6. Transcript Output Format

```markdown
---
date: 2024-11-29
time: 14:32:45
duration: "45:30"
processing_time: "23.4s"
word_count: 4,247
---

# Call Recording - Nov 29, 2024, 2:32 PM

## Summary
[AI-generated summary will appear here]

---

[00:00] [Mic] "Good morning everyone, thanks for joining."

[00:03] [SysAudio] "Hey! Good to see you. Can everyone see my screen?"

[00:07] [Mic] "Yes, looks great. Let's dive into the agenda."

[00:12] [SysAudio] "Perfect. So first item is the Q4 planning..."

[00:45] [Mic] "I think we should prioritize the mobile app."

[00:48] [SysAudio] "Agreed. What's the timeline looking like?"

...

---

*Generated by Transcripted • Duration: 45:30 • 4,247 words*
```

---

## User Experience

### First-Time User Journey

```
┌─────────────────────────────────────────────────────────────────┐
│                      ONBOARDING FLOW                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Step 1: Welcome                                                │
│  ─────────────────                                              │
│  "Welcome to Transcripted"                                      │
│  Brief introduction, warm tone                                  │
│                                                                 │
│  Step 2: How It Works                                           │
│  ────────────────────                                           │
│  Visual explanation of the capture + transcribe flow            │
│                                                                 │
│  Step 3: Permissions                                            │
│  ───────────────────                                            │
│  Request: Microphone access                                     │
│  Request: Screen Recording (system audio capture)               │
│                                                                 │
│  Step 4: Ready!                                                 │
│  ────────────                                                   │
│  "You're all set. Click the pill to start recording."           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Daily User Journey

```
Morning: User has a meeting starting
         ↓
         User clicks the floating pill to start recording
         ↓
         Pill expands to show waveform + timer
         ↓
         Meeting ends, user clicks Stop on the pill
         ↓
         Audio uploaded to Deepgram Nova-3 for transcription
         ↓
         Gemini 2.5 Pro extracts action items + summary
         ↓
         Checkmark animation, notification: "Transcript saved"
         ↓
         User clicks notification to open Markdown file
         ↓
         Transcript with action items ready in ~/Documents/Transcripted/
```

### Accessibility Features

| Feature | Implementation |
|---------|----------------|
| **Reduced Motion** | Instant transitions instead of animations |
| **High Contrast** | Clear color differentiation in all states |
| **Audio Cues** | System sounds for start/stop recording |
| **Keyboard Navigation** | Full keyboard support planned |
| **VoiceOver** | SwiftUI accessibility labels |

---

## Privacy & Security

### Privacy Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     PRIVACY BY DESIGN                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   YOUR MAC                           CLOUD SERVICES             │
│   ────────                           ──────────────             │
│                                                                 │
│   🎤 Audio Capture ──────────┐                                  │
│                              │       ☁️ Deepgram Nova-3          │
│   📁 Local Storage ◄─────────┤       (Transcription API)        │
│   (Your Documents folder)    │                                  │
│                              │       🤖 Gemini 2.5 Pro          │
│   🔐 Auth via Keychain       │       (AI summarization)         │
│   (Secure token storage)     │                                  │
│                                                                 │
│   ✅ Audio sent to Deepgram for transcription only              │
│   ✅ Transcripts stored locally in ~/Documents/Transcripted/    │
│   ❌ No third-party analytics        ❌ No advertising           │
│   ❌ No usage tracking                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Data Handling

| Data Type | Storage | Shared? | Retention |
|-----------|---------|---------|-----------|
| **Audio files** | Local + sent to Deepgram for transcription | Deepgram API only | Deleted locally after transcription |
| **Transcripts** | Local + optional cloud | User choice | User controlled |
| **Auth tokens** | macOS Keychain | Never | Until logout |
| **Preferences** | UserDefaults | Never | Persistent |
| **Usage analytics** | None collected | N/A | N/A |

### Compliance Considerations

| Regulation | Status |
|------------|--------|
| **GDPR** | Review required — Audio sent to Deepgram and text sent to Gemini cloud APIs |
| **CCPA** | Compliant — No personal data sale |
| **HIPAA** | Review required — Audio is sent to Deepgram cloud API for transcription |
| **SOC 2** | Cloud tier: In progress |

### Permissions Required

| Permission | Purpose | Required? |
|------------|---------|-----------|
| **Microphone** | Record user's voice | Yes |
| **Screen Recording** | System audio capture | Yes |
| **Internet** | Deepgram Nova-3 cloud transcription and Gemini AI | Yes |
| **Accessibility** | Global hotkeys (future) | Optional |

---

## Roadmap & Future Vision

### Near-Term (Q1 2025)

| Feature | Priority | Status |
|---------|----------|--------|
| AI-Powered Summaries | High | Planned |
| Full-Text Search | High | Planned |
| Obsidian Integration | Medium | Planned |
| Keyboard Shortcuts | Medium | Planned |
| Export to PDF/DOCX | Low | Planned |

### Mid-Term (Q2-Q3 2025)

| Feature | Description |
|---------|-------------|
| **Speaker Diarization** | Identify and label different speakers automatically — **Shipped** (via Deepgram multichannel) |
| **Action Item Extraction** | AI detects commitments and to-dos — **Shipped** (via Gemini 2.5 Pro two-pass pipeline) |
| **Calendar Integration** | Auto-name transcripts based on calendar events |
| **Notion/Roam Export** | Direct integration with popular note apps |
| **Team Workspaces** | Shared transcript libraries |

### Long-Term Vision (2026+)

| Initiative | Description |
|------------|-------------|
| **iOS Companion** | View and search transcripts on iPhone |
| **Windows Version** | Expand TAM with Windows support |
| **Real-Time Subtitles** | Live captions overlay during meetings |
| **Meeting Analytics** | Speaking time, sentiment, engagement metrics |
| **Enterprise Edition** | SSO, admin controls, audit logs |

### Integration Ecosystem

```
                    ┌────────────────┐
                    │  TRANSCRIPTED  │
                    │    (Core)      │
                    └───────┬────────┘
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
       ▼                   ▼                   ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Obsidian   │     │   Notion    │     │   Zapier    │
│  Plugin     │     │   Export    │     │   Webhook   │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │
       ▼                   ▼                   ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Raycast    │     │ Salesforce  │     │   Slack     │
│  Extension  │     │   Sync      │     │   Bot       │
└─────────────┘     └─────────────┘     └─────────────┘
```

---

## Metrics & Success Criteria

### Key Performance Indicators (KPIs)

| Category | Metric | Target (Year 1) |
|----------|--------|-----------------|
| **Acquisition** | Monthly downloads | 1,000+ |
| **Activation** | Complete onboarding | 70%+ |
| **Engagement** | Weekly active users | 40% of installs |
| **Retention** | 30-day retention | 25%+ |
| **Revenue** | Free → Pro conversion | 5%+ |
| **Satisfaction** | App Store rating | 4.5+ stars |

### Product Health Metrics

| Metric | Target |
|--------|--------|
| **Transcription accuracy** | 90%+ (measured by user feedback) |
| **Processing time** | <1 minute per 10 minutes of audio |
| **Crash-free sessions** | 99.5%+ |
| **Deepgram API success rate** | 99%+ |
| **Gemini AI pipeline success rate** | 95%+ |

### User Feedback Channels

1. **In-app feedback** — Settings → Send Feedback
2. **App Store reviews** — Monitored and responded to
3. **Twitter/X** — @TranscriptedApp (planned)
4. **Discord community** — For power users (planned)
5. **Email support** — support@transcripted.app

---

## Appendix: Technical Specifications

### System Requirements

| Requirement | Specification |
|-------------|---------------|
| **macOS Version** | 14.2 (Sonoma) or later |
| **Architecture** | Apple Silicon (M1+) and Intel |
| **RAM** | 4GB minimum, 8GB recommended |
| **Storage** | 100MB app + transcript storage |
| **Internet** | Required for Deepgram transcription and Gemini AI |

### Audio Specifications

| Parameter | Value |
|-----------|-------|
| **Sample Rate** | 48kHz (native), supports 44.1/96kHz |
| **Bit Depth** | 32-bit float |
| **Channels** | Mono (mic), Stereo (system) |
| **Format** | WAV (recording), deleted after transcription |

### Transcript Specifications

| Parameter | Value |
|-----------|-------|
| **Format** | Markdown (.md) |
| **Encoding** | UTF-8 |
| **Metadata** | YAML frontmatter |
| **Timestamps** | MM:SS format, per-segment |

### API Specifications (Cloud Sync) — **Planned — Not Yet Implemented**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/auth/login` | POST | User authentication |
| `/api/auth/signup` | POST | Account creation |
| `/api/transcripts/upload` | POST | Upload transcript |
| `/api/transcripts` | GET | List user transcripts |

### File System Structure

```
~/Documents/Transcripted/
├── Call_2024-11-29_14-32-45.md
├── Call_2024-11-29_16-00-00.md
├── failed_transcriptions.json  (retry queue)
└── ...
```

---

## Conclusion

**Transcripted** represents a new approach to meeting transcription: friction-free, AI-powered, and genuinely useful. By combining Deepgram Nova-3 cloud transcription with a two-pass Gemini 2.5 Pro AI pipeline, and focusing relentlessly on user experience, we've built a tool that knowledge workers will love and trust.

The market opportunity is substantial, the technical foundation is solid, and the product-market fit signals are strong. With a clear monetization path through cloud sync and AI features, Transcripted is positioned to become the default meeting companion for Mac users who want accurate transcripts with automatic action items.

---

*Document Version: 2.0*
*Last Updated: February 27, 2026*
*Author: Product & Engineering Team*

---

## Contact

For questions about this document or Transcripted:

- **Product**: product@transcripted.app
- **Technical**: engineering@transcripted.app
- **Press**: press@transcripted.app
