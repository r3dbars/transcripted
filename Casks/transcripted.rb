cask "transcripted" do
  version "1.1.77"
  sha256 "9fd2084d61485f0718926c669715f4a02f447b65fd2044a7b9f5e17e746cc182"

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
