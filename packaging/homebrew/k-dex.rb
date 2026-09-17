# Homebrew cask for K-Dex. Lives in a tap repo (e.g. <user>/homebrew-tap,
# under Casks/k-dex.rb). After each release: bump version, paste the DMG's
# sha256 (printed by scripts/release.sh).
cask "k-dex" do
  version "1.2.1"
  sha256 "daffcfdb0d4a4577f7b75b40640b32481ff731d9b8e9c7bd6f4b9c9d36f688e4"

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
