cask "transcripted" do
  version "1.1.76"
  sha256 "c9c59dd56244592c200cccbc659ec103fda9a3a2cf06b1c6200369a9ef83c913"

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
