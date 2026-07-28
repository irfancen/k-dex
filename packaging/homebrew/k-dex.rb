# Homebrew cask for K-Dex. Lives in a tap repo (e.g. <user>/homebrew-tap,
# under Casks/k-dex.rb). After each release: bump version, paste the DMG's
# sha256 (printed by scripts/release.sh).
cask "k-dex" do
  version "1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/irfancen/k-dex/releases/download/v#{version}/K-Dex-#{version}.dmg"
  name "K-Dex"
  desc "Fast, native Kubernetes desktop client"
  homepage "https://github.com/irfancen/k-dex"

  depends_on macos: ">= :tahoe"

  app "K-Dex.app"

  zap trash: [
    "~/Library/Preferences/com.irfancen.k-dex.plist",
    "~/Library/Saved Application State/com.irfancen.k-dex.savedState",
  ]
end
