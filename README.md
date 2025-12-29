# Murmur

A lightweight macOS app for instant on-device speech-to-text transcription. Built with Swift, SwiftUI, and Apple's Speech Framework.

## Features

✅ **Floating UI** - Always-on-top overlay that doesn't interrupt your workflow
✅ **Global Hotkey** - Press `Ctrl+Shift+F16` to start/stop recording
✅ **On-Device Processing** - 100% local transcription (no internet required)
✅ **Real-Time Display** - See transcription appear as you speak
✅ **Auto-Copy** - Transcribed text automatically copies to clipboard
✅ **Menu Bar Integration** - Convenient access from system tray
✅ **Audio Visualization** - Visual feedback while recording

## How to Use

1. **Launch Murmur** - The app appears in your menu bar (microphone icon)
2. **Start Recording** - Press `Ctrl+Shift+F16` (customizable in settings)
3. **Speak** - Your speech is transcribed in real-time
4. **Stop Recording** - Press the hotkey again
5. **Paste Anywhere** - Use `Cmd+V` to paste your transcribed text

## Building

### Requirements
- macOS 13.0+
- Xcode 15.0+
- Apple Silicon or Intel Mac

### Build Steps

```bash
cd Murmur.xcodeproj
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Release build
```

Or open `Murmur.xcodeproj` in Xcode and press `Cmd+B`.

## Permissions

On first launch, Murmur requests:

- **Speech Recognition** - For on-device transcription
- **Microphone Access** - To capture your voice
- **Accessibility** (optional) - For global hotkey functionality

## Architecture

```
Murmur/
├── Core/              # Business logic
│   ├── Transcription.swift
│   ├── Audio.swift
│   ├── Hotkey.swift
│   └── Clipboard.swift
├── UI/                # SwiftUI views
│   ├── FloatingPanel.swift
│   └── Settings.swift
├── MurmurApp.swift    # App entry point
└── Info.plist         # Configuration
```

## Privacy & Security

- ✅ 100% on-device processing
- ✅ No data sent to external servers
- ✅ No analytics or tracking
- ✅ Microphone access only when recording

## Troubleshooting

### Hotkey Not Working

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Add **Murmur** to allowed apps
3. Restart Murmur

### Microphone Not Detected

1. Open **System Settings** → **Privacy & Security** → **Microphone**
2. Enable access for **Murmur**

## License

MIT License

---

**Murmur** - Your voice, instantly transcribed.  
