# Sparkle Auto-Update

Mailia uses Sparkle 2. The update feed URL, public EdDSA key, and bundle
version live in `Sources/MailiaApp/Info.plist`, which SwiftPM embeds into the
executable through the linker.

The release workflow syncs `SUFeedURL` to the current GitHub repository, bumps
`VERSION` and the bundle version, builds `Mailia-<version>-macos.dmg`, uploads
it to GitHub Releases, signs the DMG with Sparkle `sign_update`, appends a new
item to `appcast.xml`, and commits the version/appcast bump back to `main`.

## Required GitHub Actions secrets

| Secret | Description |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded `.p12` signing certificate |
| `P12_PASSWORD` | Password for the `.p12` file |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `SPARKLE_ED_PRIVATE_KEY` | Private EdDSA key exported by Sparkle `generate_keys -x` |

`SUPublicEDKey` is generated for Mailia with Sparkle account `dev.rhinoc.mailia`. Store the matching exported private key in `SPARKLE_ED_PRIVATE_KEY`.

## Local release build

```bash
npm --prefix Web/Timeline ci
MAILIA_ALLOW_ADHOC_SIGNING=1 scripts/build_release.sh
```

`scripts/build_release.sh` rebuilds the timeline web bundle, builds the SwiftPM
release product, assembles `Mailia.app`, copies `Sparkle.framework`, signs the
app, and creates the DMG with `appdmg`.

Useful environment variables:

| Variable | Description |
| --- | --- |
| `MAILIA_ALLOW_ADHOC_SIGNING=1` | Allow ad-hoc app signing when no Apple signing identity is available |
| `APPDMG_VERSION` | Override the `appdmg` npm package version, defaulting to `0.6.6` |
| `SPARKLE_RELEASE_VERSION` | Override the Sparkle tools release downloaded by `scripts/update_appcast.sh`, defaulting to `2.9.2` |

If signing certificate secrets are not configured, CI sets
`MAILIA_ALLOW_ADHOC_SIGNING=1` so the release workflow can still publish a DMG
and appcast. Developer ID signing plus notarization should be added before
distributing to users who expect a normal first-launch experience.
