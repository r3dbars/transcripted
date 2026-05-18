cask "transcripted" do
  version "1.1.41"
  sha256 "b83547ad9f80c03a12e11f25d3c2ff074ed9c45bcc442ad45913d4e16cf675cf"

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
