# Releasing K-Dex

## One-time setup

1. **Developer ID certificate** — Xcode → Settings → Accounts → Manage
   Certificates → **+** → *Developer ID Application*.
2. **Notarization credentials** — create an app-specific password at
   appleid.apple.com, then:

   ```sh
   xcrun notarytool store-credentials kdex-notary \
     --apple-id <apple-id> --team-id <team-id> --password <app-specific-pw>
   ```

3. **GitHub repo** — create it and push (install `gh` with
   `brew install gh`, then):

   ```sh
   gh auth login
   gh repo create k-dex --public --source . --push
   ```

4. **Homebrew tap** — create a `homebrew-tap` repo, copy
   `packaging/homebrew/k-dex.rb` into `Casks/`, and replace the
   placeholders. Users then install with:

   ```sh
   brew install --cask <user>/tap/k-dex
   ```

## Each release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in the project.
2. `scripts/release.sh` — builds, signs, notarizes, staples; prints the DMG
   sha256.
3. Tag and publish:

   ```sh
   git tag v<version> && git push --tags
   gh release create v<version> build/K-Dex-<version>.dmg --title "K-Dex <version>"
   ```

4. Update the cask in the tap: `version` + `sha256`.

## Notes

- The build bundles kubectl into `Contents/Helpers/` (from `$KDEX_KUBECTL`,
  falling back to `kubectl` on PATH / Homebrew). The app prefers the bundled
  copy; the Settings override still wins.
- The app icon is generated: `swift scripts/generate-icon.swift <out.png>`.
- Sparkle auto-updates are planned but not wired yet (needs EdDSA keys and
  an appcast fed from GitHub Releases).
