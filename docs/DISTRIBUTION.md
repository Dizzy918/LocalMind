# Distributing LocalMind

How releases are built and how to install them.

## Installing a release

### From the DMG

1. Download `LocalMind.dmg` from the [Releases page](https://github.com/Dizzy918/LocalMind/releases).
2. Open it and drag **LocalMind** to **Applications**.
3. Launch it.
   - **Signed & notarized builds** (official releases) open normally.
   - **Ad-hoc builds** (forks without an Apple Developer account) are blocked by Gatekeeper on first launch. Right-click the app → **Open** → **Open**, once. After that it launches normally.

Every release also ships a `LocalMind.dmg.sha256` — verify with:

```bash
shasum -a 256 -c LocalMind.dmg.sha256
```

### With Homebrew

Once you've published a tap (see below):

```bash
brew install --cask <your-tap>/localmind
```

## Cutting a release

Releases are built by [`.github/workflows/release.yml`](../.github/workflows/release.yml), triggered by pushing a `v*` tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow archives the app, packages a DMG, creates a GitHub Release, and attaches the DMG plus its checksum. You can also run it manually from the Actions tab (**workflow_dispatch**).

### Signing & notarization (optional but recommended)

If these repository secrets are set, the release is signed with your Developer ID and notarized so it opens without the Gatekeeper prompt. If they're absent, the workflow automatically falls back to an ad-hoc-signed DMG, so a tag always produces an installable artifact.

| Secret | What it is |
|--------|-----------|
| `MAC_DEVELOPER_ID_P12_BASE64` | Your "Developer ID Application" certificate exported as `.p12`, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `MAC_DEVELOPER_ID_P12_PASSWORD` | Password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any string — a throwaway password for the temporary CI keychain |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID |
| `NOTARY_APPLE_ID` | The Apple ID email used for notarization |
| `NOTARY_APP_PASSWORD` | An [app-specific password](https://support.apple.com/en-us/102654) for that Apple ID |

## Publishing a Homebrew cask

1. Create a public repo named **`homebrew-localmind`** (the `homebrew-` prefix is what makes it a tap).
2. Copy [`Casks/localmind.rb`](../Casks/localmind.rb) into it at `Casks/localmind.rb`.
3. After each release, update `version` and the `sha256` values from the release's `.dmg.sha256` file.
4. Users install with `brew install --cask <you>/localmind/localmind`.

## Continuous integration

[`.github/workflows/build.yml`](../.github/workflows/build.yml) builds the app and runs the unit test suite on every push and PR to `main`. The UI smoke tests (`LocalMindUITests`) are skipped in CI — they need a full window-server session and are meant for local pre-release verification:

```bash
xcodebuild test -project LocalMind.xcodeproj -scheme LocalMind -destination 'platform=macOS'
```
