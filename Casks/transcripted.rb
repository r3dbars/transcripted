cask "transcripted" do
  version "1.1.55"
  sha256 "1778610ac749f4abb20cd606914504ebab04607425353df9f98e12a6cf6cff46"

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
