cask "transcripted" do
  version "1.1.64"
  sha256 "11f315f8a920a3b54e92e453df2d7853d71f9d8467a853566b805381ddfbb839"

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
    "~/Library/Preferences/com.justinbetker.draft.plist",
  ]
end
