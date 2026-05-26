cask "status-box" do
  version "1.0.0"
  sha256 "c380abf1ab21f67b7ab2c583903d021608f99b399301dc03f41119ca563401d5"

  url "https://github.com/elixirevo/statusbox/releases/download/v#{version}/StatusBox-#{version}-universal.dmg"
  name "Status Box"
  desc "Native macOS menu bar utility for hiding and opening status bar apps"
  homepage "https://github.com/elixirevo/statusbox"

  depends_on macos: ">= :ventura"

  app "StatusBox.app"

  uninstall quit: "com.elixirevo.StatusBox"

  zap trash: [
    "~/Library/Preferences/com.elixirevo.StatusBox.plist",
  ]
end
