cask "transcripted" do
  version "1.1.25"
  sha256 "0a91536b468c96db9d234dfb3d17e9c2c0c28b95637882857e4ca65193dae72d"

  url "https://github.com/r3dbars/transcripted/releases/download/v#{version}/Transcripted-#{version}.dmg",
      verified: "github.com/r3dbars/transcripted/"
  name "Transcripted"
  desc "Menubar app for dictation and meeting transcription"
  homepage "https://transcripted.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Transcripted.app"

  zap trash: [
    "~/Library/Application Support/Transcripted",
    "~/Library/Caches/com.justinbetker.draft",
    "~/Library/Preferences/com.justinbetker.draft.plist",
  ]
end
