cask "transcripted" do
  version "1.1.72"
  sha256 "54fd1f25bda00f6ff3285e25c6c1abe5cc54e28f92fc3767b58712d73dddd308"

  url "https://github.com/r3dbars/transcripted/releases/download/v#{version}/Transcripted-#{version}.dmg"
  name "Transcripted"
  desc "Menubar app for dictation and meeting transcription"
  homepage "https://transcripted.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Transcripted.app"

  zap trash: [
    "~/Library/Application Support/Transcripted",
    "~/Library/Caches/com.justinbetker.draft",
    "~/Library/Input Methods/Transcripted Keyboard.app",
    "~/Library/Preferences/com.justinbetker.draft.plist",
    "~/Library/Preferences/com.justinbetker.draft.inputmethod.Transcripted.plist",
    "~/Library/Preferences/com.justinbetker.draft.writing.plist",
  ]
end
