cask "transcripted" do
  version "1.1.34"
  sha256 "0cf7d0894cf0ac9290b110763e0ab5266f195111f6213704c1864d361b685f23"

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
