cask "transcripted" do
  version "1.1.10"
  sha256 "f7a2a1ef59602dd1569f5c019fdf205ad95bee4b35dd8520c2a89d46c98e5e07"

  url "https://github.com/r3dbars/transcripted/releases/download/v#{version}/Transcripted-#{version}.dmg",
      verified: "github.com/r3dbars/transcripted/"
  name "Transcripted"
  desc "Local macOS menubar app for dictation and meeting transcription"
  homepage "https://transcripted.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "Transcripted.app"

  zap trash: [
    "~/Library/Application Support/Transcripted",
    "~/Library/Caches/com.transcripted.Transcripted",
    "~/Library/Preferences/com.transcripted.Transcripted.plist",
  ]
end
