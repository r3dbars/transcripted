# Settings Redesign Plan: Monologue-Inspired Dashboard

> **STATUS: PARTIALLY IMPLEMENTED (Feb 2026)**
> This was the original planning document. The actual implementation simplified the design:
> - Dashboard and Preferences tabs were implemented
> - TranscriptsView and HelpView were **not** built (descoped)
> - Meeting Detection toggle was **removed** (MeetingDetector deleted from codebase)
> - The old unified `Settings.swift` was deleted and replaced by the `Settings/` directory
> - See `CLAUDE.md` for the current architecture

## Overview

Transform the current 3-tab settings panel into a full-featured dashboard with sidebar navigation, inspired by Monologue's elegant design. This redesign will feature a stats dashboard, transcript browser, comprehensive settings, and help section while maintaining Transcripted's dark charcoal/coral brand aesthetic.

---

## Visual Reference

**Monologue Inspiration:**
- Left sidebar with navigation items (Dashboard, Transcripts, Settings, Help)
- Right content area with stats cards, heat map, recent items
- Dark theme with accent colors
- Clean, modern layout with cards

**Transcripted Brand Adaptation:**
- Dark charcoal (`#1A1A1A`) background
- Coral (`#FF6B6B`) accent for recording/action states
- Warm cream (`#FAF7F2`) for card highlights on hover
- Laws of UX styling (12pt card radius, subtle shadows)

---

## Architecture

### New Files to Create

```
Murmur/UI/Settings/
├── SettingsWindowController.swift    # NSWindowController for window management
├── SettingsContainerView.swift       # Main SwiftUI view with sidebar + content
├── SettingsSidebarView.swift         # Left navigation sidebar
├── Tabs/
│   ├── DashboardView.swift           # Stats dashboard (main view)
│   ├── TranscriptsView.swift         # Transcript browser
│   ├── PreferencesView.swift         # Actual settings/preferences
│   └── HelpView.swift                # FAQ and support links
├── Components/
│   ├── StatsCardView.swift           # Individual stat card (hours, items, etc.)
│   ├── HeatMapView.swift             # Monthly activity heat map
│   ├── RecentTranscriptsView.swift   # Recent transcripts list
│   ├── TranscriptRowView.swift       # Single transcript row
│   ├── StreakBadgeView.swift         # Streak display
│   └── SettingsSectionCard.swift     # Reusable settings section card
└── Models/
    └── SettingsNavigationState.swift # Navigation state manager

Murmur/Core/
├── StatsDatabase.swift               # SQLite stats persistence
├── StatsService.swift                # Stats calculation and aggregation
└── TranscriptScanner.swift           # Scans folder for transcript metadata
```

### Files to Modify

- `TranscriptedApp.swift` - Update `openSettings()` to use new controller
- `TranscriptSaver.swift` - Add stats tracking after save
- `TranscriptionTaskManager.swift` - Track action item counts
- `DesignTokens.swift` - Add new tokens for settings UI

---

## Data Layer: Stats Database

### Database Schema (SQLite)

```sql
-- Recording sessions
CREATE TABLE recordings (
    id TEXT PRIMARY KEY,
    date TEXT NOT NULL,           -- ISO 8601 date
    time TEXT NOT NULL,           -- HH:mm:ss
    duration_seconds INTEGER,     -- Total seconds
    word_count INTEGER,
    speaker_count INTEGER,
    processing_time_ms INTEGER,
    transcript_path TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

-- Action items (tracked before sending to external service)
CREATE TABLE action_items (
    id TEXT PRIMARY KEY,
    recording_id TEXT,
    task TEXT NOT NULL,
    owner TEXT,
    priority TEXT,
    due_date TEXT,
    destination TEXT,             -- 'reminders' or 'todoist'
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (recording_id) REFERENCES recordings(id)
);

-- Daily activity (for heat map)
CREATE TABLE daily_activity (
    date TEXT PRIMARY KEY,        -- YYYY-MM-DD
    recording_count INTEGER DEFAULT 0,
    total_duration_seconds INTEGER DEFAULT 0,
    action_items_count INTEGER DEFAULT 0,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```

### StatsService API

```swift
@MainActor
class StatsService: ObservableObject {
    // Published stats for UI binding
    @Published var totalHoursTranscribed: Double = 0
    @Published var totalRecordings: Int = 0
    @Published var totalActionItems: Int = 0
    @Published var currentStreak: Int = 0
    @Published var longestStreak: Int = 0
    @Published var averageMeetingDuration: TimeInterval = 0
    @Published var monthlyActivity: [Date: DailyActivity] = [:]

    // Methods
    func recordSession(_ metadata: RecordingMetadata) async
    func recordActionItems(_ items: [ActionItem], for recordingId: String) async
    func refreshStats() async
    func getRecentTranscripts(limit: Int) -> [TranscriptSummary]
    func getActivityForMonth(_ date: Date) -> [Date: DailyActivity]
}
```

---

## UI Components

### 1. SettingsWindowController

**Window Configuration:**
- Size: 800x600 (fixed, matching Monologue proportions)
- Style: `.titled, .closable` (no resize for consistent layout)
- Background: Dark with optional frosted glass effect
- Centered on screen

```swift
class SettingsWindowController: NSWindowController {
    private var statsService: StatsService
    private var navigationState = SettingsNavigationState()

    init(statsService: StatsService) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // ... configure window
    }
}
```

### 2. SettingsContainerView (Main Layout)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  ┌──────────────┐  ┌──────────────────────────────────────────────────┐│
│  │              │  │                                                  ││
│  │  Transcripted│  │                    Content Area                  ││
│  │              │  │                                                  ││
│  │  ○ Dashboard │  │   (Dashboard / Transcripts / Preferences / Help) ││
│  │  ○ Transcripts│  │                                                  ││
│  │  ○ Settings  │  │                                                  ││
│  │  ○ Help      │  │                                                  ││
│  │              │  │                                                  ││
│  │              │  │                                                  ││
│  │              │  │                                                  ││
│  │  ──────────  │  │                                                  ││
│  │  v1.0.0      │  │                                                  ││
│  └──────────────┘  └──────────────────────────────────────────────────┘│
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
     180px                           620px
```

### 3. DashboardView (Stats Dashboard)

```
┌────────────────────────────────────────────────────────────────┐
│  Stats (last 30 days)                                          │
│  ┌──────────────────────────────────────────────┐ ┌──────────┐│
│  │                                              │ │  🔥 12   ││
│  │  Hours Transcribed    Meetings    Action Items │ │  day    ││
│  │     14.5h              23           47       │ │  streak ││
│  │                                              │ │          ││
│  └──────────────────────────────────────────────┘ └──────────┘│
│                                                                │
│  ┌────────────────────────────────────────────────────────────┐│
│  │ "You've been on a roll! 12 days straight of meetings."    ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  Monthly activity                          Recent transcripts  │
│  ┌──────────────────────┐                 ┌──────────────────┐│
│  │  S  M  T  W  T  F  S │                 │ ○ Team Standup   ││
│  │  ▪  ▪  ▪  ▪  ▪  ▪  ▪ │                 │   Today 9:00 AM  ││
│  │  ▪  ▪  ▪  ▪  ▪  ▪  ▪ │                 │ ○ Client Call    ││
│  │  ▪  ▪  ▪  ▫  ▫  ▪  ▪ │                 │   Yesterday 2pm  ││
│  │  ▪  ▫  ▫  ▫  ▫  ▫  ▪ │                 │ ○ 1:1 with Sarah ││
│  │                      │                 │   Jan 3, 11am    ││
│  │  🔥 18 active days   │                 │                  ││
│  └──────────────────────┘                 └──────────────────┘│
└────────────────────────────────────────────────────────────────┘
```

**Stats Cards:**
- Hours Transcribed (sum of all durations)
- Total Meetings (recording count)
- Action Items Created (from action_items table)
- Current Streak (consecutive days with recordings)

**Heat Map:**
- 4-5 rows showing current month
- Intensity based on recording count/duration
- Hover shows: "3 meetings, 2h 15m total, 8 action items"
- Fire emoji + "X active days" below

**Motivational Message:**
- Dynamic based on stats
- Examples: "You've been on a roll!", "Great week - 5 meetings captured!"

### 4. TranscriptsView (Transcript Browser)

```
┌────────────────────────────────────────────────────────────────┐
│  Transcripts                                          [Search] │
│                                                                │
│  ┌────────────────────────────────────────────────────────────┐│
│  │ 📄 Team Standup                              Jan 5, 2026   ││
│  │    45 min • 4 speakers • 3 action items                    ││
│  ├────────────────────────────────────────────────────────────┤│
│  │ 📄 Client Kickoff - Acme Corp               Jan 4, 2026    ││
│  │    1h 23min • 6 speakers • 7 action items                  ││
│  ├────────────────────────────────────────────────────────────┤│
│  │ 📄 Product Review                           Jan 3, 2026    ││
│  │    32 min • 3 speakers • 2 action items                    ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  Click to reveal in Finder                                     │
└────────────────────────────────────────────────────────────────┘
```

**Features:**
- Scrollable list of all transcripts
- Search/filter by title
- Click to open Finder at transcript location
- Shows preview info (duration, speakers, action items)

### 5. PreferencesView (Settings)

Reorganized into clear sections:

```
┌────────────────────────────────────────────────────────────────┐
│  Preferences                                                   │
│                                                                │
│  ┌─ Storage ──────────────────────────────────────────────────┐│
│  │ 📁 Save Location                                           ││
│  │    ~/Documents/Transcripted/              [Choose...]      ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─ Profile ──────────────────────────────────────────────────┐│
│  │ 👤 Your Name                                               ││
│  │    [Justin Betker                              ]           ││
│  │    Used for speaker identification and task attribution    ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─ Appearance ───────────────────────────────────────────────┐│
│  │ 🎨 Aurora Recording Indicator        [Toggle]              ││
│  │    Flowing color animation during recording                ││
│  │                                                            ││
│  │ 🔔 Sound Feedback                    [Toggle]              ││
│  │    Play sounds when recording starts/stops                 ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─ Recording ────────────────────────────────────────────────┐│
│  │ 📹 Meeting Detection                 [Toggle]              ││
│  │    Auto-detect video calls and prompt to record            ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─ Task Integration ─────────────────────────────────────────┐│
│  │ ✅ Task Destination                                        ││
│  │    ( ) Apple Reminders                                     ││
│  │    ( ) Todoist                                             ││
│  │                                                            ││
│  │ 🔑 Todoist API Key (if selected)                          ││
│  │    [••••••••••••••••••••]                    [Verify]      ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─ AI Services ──────────────────────────────────────────────┐│
│  │ 🎤 Deepgram API Key                                        ││
│  │    [••••••••••••••••••••]                    [Verify]      ││
│  │                                                            ││
│  │ ✨ Gemini API Key                                          ││
│  │    [••••••••••••••••••••]                    [Verify]      ││
│  └────────────────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────────────────┘
```

**Sections:**
1. **Storage** - Save location picker
2. **Profile** - User's name
3. **Appearance** - Aurora indicator, sound feedback
4. **Recording** - Meeting detection
5. **Task Integration** - Reminders/Todoist choice + API key
6. **AI Services** - Deepgram and Gemini API keys

### 6. HelpView (FAQ & Support)

```
┌────────────────────────────────────────────────────────────────┐
│  Help                                                          │
│                                                                │
│  ┌─ Frequently Asked Questions ───────────────────────────────┐│
│  │                                                            ││
│  │ ▶ How do I start a recording?                             ││
│  │   Click the floating pill or use the keyboard shortcut...  ││
│  │                                                            ││
│  │ ▶ Why isn't system audio being captured?                  ││
│  │   System audio requires Screen Recording permission...     ││
│  │                                                            ││
│  │ ▶ How do action items work?                               ││
│  │   After transcription, Gemini AI extracts action items... ││
│  │                                                            ││
│  │ ▶ Where are my transcripts saved?                         ││
│  │   By default in ~/Documents/Transcripted/...              ││
│  │                                                            ││
│  │ ▶ How do I get API keys?                                  ││
│  │   Deepgram: deepgram.com, Gemini: aistudio.google.com...  ││
│  │                                                            ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─ Keyboard Shortcuts ───────────────────────────────────────┐│
│  │ ⌘ + R     Start/Stop Recording                            ││
│  │ ⌘ + ,     Open Settings                                   ││
│  │ ⌘ + Q     Quit Transcripted                               ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌─ Support ──────────────────────────────────────────────────┐│
│  │ 📧 Send Feedback                   [Open Email]           ││
│  │ 📖 Documentation                   [Open in Browser]      ││
│  │ 🐛 Report a Bug                    [Open GitHub]          ││
│  └────────────────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────────────────┘
```

**Sections:**
1. **FAQ** - Expandable/collapsible questions
2. **Keyboard Shortcuts** - Quick reference
3. **Support** - Feedback email, documentation, bug reports

---

## Implementation Phases

### Phase 1: Data Layer (Foundation)
**Estimated complexity: Medium**

1. Create `StatsDatabase.swift` with SQLite setup
2. Create `StatsService.swift` with stats calculation
3. Create `TranscriptScanner.swift` for initial migration
4. Modify `TranscriptSaver.swift` to record sessions
5. Modify `TranscriptionTaskManager.swift` to track action items
6. Add migration: scan existing transcripts to populate database

### Phase 2: Window & Navigation Infrastructure
**Estimated complexity: Medium**

1. Create `SettingsWindowController.swift`
2. Create `SettingsNavigationState.swift` (ObservableObject)
3. Create `SettingsContainerView.swift` with sidebar layout
4. Create `SettingsSidebarView.swift`
5. Update `TranscriptedApp.swift` to use new controller
6. Test basic navigation between empty tab views

### Phase 3: Dashboard Implementation
**Estimated complexity: High**

1. Create `StatsCardView.swift` component
2. Create `HeatMapView.swift` with hover details
3. Create `StreakBadgeView.swift`
4. Create `RecentTranscriptsView.swift`
5. Create `TranscriptRowView.swift`
6. Assemble `DashboardView.swift`
7. Wire up StatsService data binding

### Phase 4: Transcripts Browser
**Estimated complexity: Medium**

1. Create full `TranscriptsView.swift`
2. Add search/filter functionality
3. Implement click-to-reveal in Finder
4. Add empty state for no transcripts

### Phase 5: Preferences Migration
**Estimated complexity: Low**

1. Create `PreferencesView.swift` reorganized from current Settings
2. Create `SettingsSectionCard.swift` component
3. Migrate all existing settings with new layout
4. Preserve all @AppStorage bindings

### Phase 6: Help Section
**Estimated complexity: Low**

1. Create `HelpView.swift`
2. Add FAQ content (expandable sections)
3. Add keyboard shortcuts reference
4. Add support links (email, docs, GitHub placeholder)

### Phase 7: Polish & Animation
**Estimated complexity: Medium**

1. Add sidebar selection animations
2. Add card hover effects
3. Add transition animations between tabs
4. Add heat map hover tooltips
5. Test accessibility (reduce motion)
6. Final design token refinements

---

## Design Tokens to Add

```swift
// DesignTokens.swift additions

// Settings Window
static let settingsWindowWidth: CGFloat = 800
static let settingsWindowHeight: CGFloat = 600
static let settingsSidebarWidth: CGFloat = 180

// Stats Dashboard
static let statsCardHeight: CGFloat = 100
static let statsCardMinWidth: CGFloat = 140
static let heatMapCellSize: CGFloat = 24
static let heatMapCellSpacing: CGFloat = 4

// Heat Map Colors (Coral intensity scale)
static let heatMapEmpty = Color.panelCharcoalSurface
static let heatMapLight = Color.recordingCoral.opacity(0.3)
static let heatMapMedium = Color.recordingCoral.opacity(0.6)
static let heatMapHigh = Color.recordingCoral
static let heatMapMax = Color.recordingCoralDeep
```

---

## Success Criteria

1. **Visual parity** with Monologue's elegance while maintaining Transcripted brand
2. **Stats dashboard** shows accurate metrics from database
3. **Heat map** displays activity with hover details
4. **Streak tracking** works correctly across days
5. **All existing settings** preserved and accessible
6. **Transcript browser** shows all transcripts with search
7. **Help section** provides useful FAQ and support paths
8. **Performance** - window opens quickly, stats load < 1s
9. **Animations** respect reduce-motion preference

---

## Migration Strategy

1. **Data migration on first launch:**
   - Scan `~/Documents/Transcripted/` for existing `.md` files
   - Parse YAML frontmatter to extract date, duration, word_count
   - Populate recordings table
   - Show progress indicator during initial scan

2. **Settings migration:**
   - All existing @AppStorage keys remain unchanged
   - No user data loss
   - Old Settings.swift can be archived after testing

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| SQLite complexity | Use GRDB.swift or raw SQLite3 with thin wrapper |
| Initial scan slowness | Background scan with progress UI, cache results |
| Heat map date calculations | Use Calendar API correctly, test timezone edge cases |
| Streak calculation bugs | Comprehensive unit tests for streak logic |
| Design inconsistency | Reuse existing DesignTokens, review with design system |

---

## Decisions Confirmed

| Question | Decision |
|----------|----------|
| Keyboard navigation | No - click only navigation |
| Mini mode | No - full window only, keep design simple |
| Recent transcripts count | 3 items on dashboard |
| Motivational messages | Dynamic based on stats (to be refined during implementation) |

---

## Summary

This plan transforms the current 3-tab settings into a 4-section dashboard with:
- **Dashboard**: Stats, heat map, streak, recent transcripts
- **Transcripts**: Full transcript browser with search
- **Preferences**: Reorganized settings in clear sections
- **Help**: FAQ, shortcuts, support links

Backed by a new SQLite stats database for persistent tracking of recordings and action items. Maintains Transcripted's dark charcoal/coral brand while achieving Monologue's elegant layout.
