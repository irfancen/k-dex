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

1. Bump `MARKETING_VERSION` (semantic versioning: MAJOR.MINOR.PATCH) and `CURRENT_PROJECT_VERSION` in the project.
2. `scripts/release.sh` — builds, signs, notarizes, staples; prints the DMG
   sha256.
3. Tag and publish — the appcast **must** ship as a release asset alongside
   the DMG, and so must any `*.delta` files `generate_appcast` produced (the
   appcast references them; Sparkle falls back to the full DMG if a delta 404s,
   but that wastes the point of deltas):

   ```sh
   git tag v<version> && git push --tags
   gh release create v<version> build/K-Dex-<version>.dmg build/*.delta \
     build/appcast.xml --title "K-Dex <version>"
   ```

4. **Mark the release "Latest" explicitly.** This is not cosmetic: the app's
   feed URL is `releases/latest/download/appcast.xml`, so whichever release
   holds the Latest label is the one serving the appcast to every installed
   copy. GitHub's "None" label can leave the *previous* release marked Latest
   — v1.1.0 shipped with stale-feed Sparkle until the label was fixed by hand.
5. Update the cask in the tap: `version` + `sha256`.

## Re-running a release

`release.sh` is idempotent — but each run produces a byte-different DMG, so
the DMG, deltas, appcast, and cask sha are **one atomic set**: publish them
from a single run, never mixed across runs.

- **Clear `~/Library/Caches/Sparkle_generate_appcast` before a re-run.**
  Stale cache entries make `generate_appcast` silently skip delta creation
  (exit 0, no warning) — v1.1.0's re-run lost its delta this way.
- Keep the previous versions' DMGs in `build/`; the generator scans the
  directory to keep older appcast entries and to compute deltas from them.
  After a from-scratch regeneration, check the *old* entries' URLs — the
  `--download-url-prefix` is applied to every item, so old DMG URLs need
  pointing back at their own release tags.
- A one-off `codesign --verify` failure naming a `.cstemp` file is a known
  transient race inside codesign (same family as the retried
  `errSecInternalComponent`) — just re-run the script.

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
