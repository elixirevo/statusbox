cask "status-box" do
  version "1.0.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/elixirevo/status-box/releases/download/v#{version}/StatusBox-#{version}-universal.dmg"
  name "Status Box"
  desc "Native macOS menu bar utility for hiding and opening status bar apps"
  homepage "https://github.com/elixirevo/status-box"

  depends_on macos: ">= :ventura"

  app "StatusBox.app"

  uninstall quit: "com.elixirevo.StatusBox"

  zap trash: [
    "~/Library/Preferences/com.elixirevo.StatusBox.plist",
  ]
end
