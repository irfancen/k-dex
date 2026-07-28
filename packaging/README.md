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
3. Tag and publish — the appcast **must** ship as a release asset alongside
   the DMG (the app's feed URL is
   `releases/latest/download/appcast.xml`):

   ```sh
   git tag v<version> && git push --tags
   gh release create v<version> build/K-Dex-<version>.dmg build/appcast.xml \
     --title "K-Dex <version>"
   ```

4. Update the cask in the tap: `version` + `sha256`.

## Notes

- The build bundles kubectl into `Contents/Helpers/` (from `$KDEX_KUBECTL`,
  falling back to `kubectl` on PATH / Homebrew). The app prefers the bundled
  copy; the Settings override still wins.
- The app icon is generated: `swift scripts/generate-icon.swift <out.png>`.
- Sparkle: the EdDSA private key lives in the login keychain ("Private key
  for signing Sparkle updates", created 2026-07-28); the public key is in
  the root Info.plist. `release.sh` signs the appcast via `generate_appcast`
  from the Sparkle SPM artifacts in DerivedData. Losing the private key
  orphans existing installs — back it up (`generate_keys -x <file>`).
