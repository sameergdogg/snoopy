# Releasing Snoopy

One command builds, signs, notarizes, staples, packages and generates the update feed:

```sh
ISSUER_ID=<issuer-uuid> ./Scripts/release.sh 0.3.0
```

Then publish **all three** assets — the appcast is not optional, see below:

```sh
gh release create v0.3.0 \
  dist/Snoopy-0.3.0.dmg dist/Snoopy-0.3.0.dmg.sha256 dist/appcast.xml \
  --title "Snoopy 0.3.0" --notes-file docs/RELEASE_NOTES_0.3.0.md
```

## Prerequisites

| What | Where |
|---|---|
| "Developer ID Application" certificate | login keychain |
| App Store Connect API key (`.p8`) + issuer UUID | `~/.appstoreconnect/private_keys/` |
| Sparkle command-line tools | `./Scripts/fetch-sparkle-tools.sh` (writes `.sparkle/`, gitignored) |
| Sparkle EdDSA private key | login keychain, service `https://sparkle-project.org` |

## The version argument is the only place a version is written

`release.sh` passes it into the build as `MARKETING_VERSION` (the numeric part — Apple rejects
a `-rc.1` suffix in `CFBundleShortVersionString`), `CURRENT_PROJECT_VERSION` (the commit
count) and `SNOOPY_RELEASE_CHANNEL` (the full string), then reads the built `Info.plist` back
and fails if any of them disagrees. Nothing in `project.yml` needs bumping by hand.

`CURRENT_PROJECT_VERSION` is what Sparkle compares, so it must increase between releases. It
is `git rev-list --count HEAD`, which it does on its own; override with `BUILD_NUMBER=` only
for local experiments.

## Why the appcast has to be attached to the release

The app's `SUFeedURL` is:

```
https://github.com/sameergdogg/snoopy/releases/latest/download/appcast.xml
```

GitHub keeps `releases/latest/download/<asset>` pointed at the newest non-prerelease, which
gives a stable feed URL with no extra hosting. The cost is that **every release must carry an
`appcast.xml` asset** — publish one without it and the redirect 404s, and every installed copy
silently stops finding updates.

`release.sh` seeds the new feed from the currently published one, so history is preserved
rather than rebuilt from a single entry each time. It also fails the release if the generated
appcast lacks an EdDSA signature or does not list the DMG just built.

## Never regenerate the EdDSA key

Updates are refused unless signed by the key matching `SUPublicEDKey` in `project.yml`.
Generating a fresh pair orphans everyone already running Snoopy — they would keep checking and
keep rejecting every update, with no way back except a manual download. On a new machine,
import the existing key into the login keychain rather than running `generate_keys`.

## Verifying before you publish

```sh
SKIP_NOTARIZE=1 ./Scripts/release.sh 0.3.0
```

Builds and signs without submitting to Apple. Useful for checking the signing step, which has
to reach inside `Sparkle.framework` and sign its nested `Updater.app`, `Autoupdate` helper and
XPC services before the framework and the app — `codesign --verify --deep --strict` at the end
is what catches a miss, rather than the notary service ten minutes later. The DMG it produces
is not distributable.

## Note on 0.2.0

0.2.0 and earlier have no updater, so the hop to 0.3.0 is manual for anyone on them. From
0.3.0 onward Sparkle handles it.
