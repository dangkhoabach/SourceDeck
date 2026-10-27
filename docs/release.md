# Releasing SourceDeck (native, macOS)

Everything runs locally on this Mac — no CI secrets, no GitHub Releases.
Same manual-publish model as SignalBar / FoldAway: build and sign
here, upload by hand to admin.dangkhoabach.vn, and Sparkle inside the
installed app picks the new version up from
`updates.dangkhoabach.vn/dkb-source-control/appcast.xml` (since
2026-10-09: 1.0.0 was installed on this Mac only and has no updater, so
1.0.1 is installed by hand once; Sparkle takes it from there).

## Why a self-signed certificate

No Apple Developer Program membership, so no Developer ID signing and no
notarization. Builds are signed with the self-signed **"SourceDeck
Local Signing"** certificate from `scripts/create-signing-cert.sh` (named in
the gitignored `Local.xcconfig`) rather than ad-hoc:

- The app runs `git` in every repository it lists. macOS asks for Desktop,
  Documents or Downloads access on behalf of the app (git is its child
  process), and keys that grant on the signing identity. An ad-hoc build gets
  a new identity every time, so every rebuild or update would ask again; the
  certificate keeps the grant.
- The app needs no Keychain item of its own: credentials stay with git's
  credential helper (`osxkeychain`).

`spctl` rejects the app ("origin=DKB Source Control Local Signing"), which is
expected for a certificate Apple doesn't know. A build made on this Mac opens
normally; a copy taken to another Mac needs System Settings › Privacy &
Security › **Open Anyway** on first launch.

## One-time setup

1. **Signing certificate** — `scripts/create-signing-cert.sh` (creates the
   certificate in the login Keychain and writes `Local.xcconfig`).
2. **Sparkle EdDSA keypair** — under the `dkb-source-control` Keychain
   account, kept separate from SignalBar's (default `ed25519` account),
   MediaCatch's and FoldAway's:
   ```bash
   .sparkle-tools/2.6.4/bin/generate_keys --account dkb-source-control
   ```
   It prints the public half, which goes into `SUPublicEDKey` in
   `SourceDeckApp/Info.plist`; the private half stays in the login
   Keychain. `--account` is required — without it the tools fall back to the
   default account and silently reuse SignalBar's key. `release.sh`
   downloads the tools (checksum-verified) on its first run, and refuses to
   build when the Keychain key and `SUPublicEDKey` don't match.
3. **`create-dmg`** — `brew install create-dmg` (styles the installer's Finder
   window with an Applications drop link).
4. **First upload** — admin.dangkhoabach.vn → Apps → "Publish new app" with
   the slug `dkb-source-control`; until then the feed answers 404 and a
   manual check reports an error.

`Info.plist` deliberately does not set `SUEnableAutomaticChecks` (same as
the other apps): Sparkle shows its own "check automatically?" prompt on the
second launch and stores the answer, which Settings › Updates reads and
writes. `AppDelegate` touches `AppUpdater.shared` at launch so the daily
scheduled check actually starts — the controller is lazy.

## Hardened Runtime and Sparkle

Release keeps Hardened Runtime. Its library validation only loads
frameworks signed by Apple or by the app's own Team ID, and a self-signed
certificate has no Team ID — so the embedded `Sparkle.framework`, although
signed by the very same certificate, is refused at launch ("mapping process
and mapped file have different Team IDs"). As in FoldAway, the
`com.apple.security.cs.disable-library-validation` entitlement
(`SourceDeckApp/SourceDeckApp.entitlements`) lifts only that
one check; `release.sh` verifies that it is the one and only entitlement.
Checked on a Release build: it starts and maps Sparkle.

Sparkle is pinned to an exact version (`2.10.0`) in the package reference,
like the other apps: bumping it is a deliberate edit that comes with
re-reading its release notes.

## Cutting a release

```bash
./scripts/release.sh 1.0.1      # or without a version: it asks, Enter keeps the current one
```

The version goes into both `CFBundleShortVersionString` and
`CFBundleVersion` in `SourceDeckApp/Info.plist` (a lower version than
the current one is refused). Before that, the Sparkle key in the Keychain
is checked against `SUPublicEDKey`. Then, in order:

1. `swift test` for `SourceDeckCore`, then the app's tests — a failure
   stops the release before anything is built.
2. Release build with the local certificate, universal (arm64 + x86_64), in a
   temporary DerivedData folder that is removed afterwards.
3. Checks on the built app: signature valid, signed by the local certificate,
   Hardened Runtime on, **only** `disable-library-validation` (no sandbox,
   no `get-task-allow`), both architectures, the version just set.
4. DMG with `create-dmg`, its SHA-256 next to it, and the Sparkle signature
   (`.sig`, raw EdDSA) under the `dkb-source-control` account.

If any step fails, `Info.plist` is put back as it was. Output lands in
`release-output/<version>/` (gitignored): the `.dmg`, its `.sha256`, its
`.sig` and the `.app`.

Commit the version bump in `Info.plist` and tag the release only when it is
decided to keep it (git-rule: commits and tags are made on request).

## Uploading a release

admin.dangkhoabach.vn → Apps → "Publish new app" for the first release
(slug `dkb-source-control`) or "Republish" afterwards, tick macOS and
upload:

| Form field | File |
|---|---|
| Installer file | `SourceDeck-<version>.dmg` |
| Sparkle signature (.sig) | `SourceDeck-<version>.dmg.sig` (paste its contents) |

Leave the Tauri-format "Updater bundle"/"Signature" fields empty. Compare
the SHA-256 the script printed with the uploaded file: the DMG and the
signature are two separate fields, and a mismatch makes every client reject
the update.

## Installing on this Mac

```bash
./scripts/install-local.sh          # newest release in release-output/
./scripts/install-local.sh 1.0.0
```

Quits the running app, replaces `/Applications/SourceDeck.app` and
opens it.

The installed app keeps its list of repositories in
`~/Library/Application Support/com.dangkhoabach.dkb-source-control/dkb-source-control.db`.
Builds run from Xcode use `dkb-source-control-debug.db` next to it, so trying
things out never touches the list the installed app uses. On a first install
the list is empty: **Scan Folder…** (⇧⌘O) on the home folder finds every
repository in a few seconds.

## Release 1.0.0 (2026-10-08)

- `./scripts/release.sh 1.0.0`: 142 Core and 19 app tests passed; signed,
  Hardened Runtime, no entitlements, arm64 + x86_64; 1 min 58 s in all.
- `SourceDeck-1.0.0.dmg`: 5.2 MB, SHA-256
  `9476feed1b5573b28d6dd315b52d940c0bcb9871ee980ebe7e32cee1be4f1171`; the app
  is 18 MB.
- Installed to `/Applications`: starts, finds `/usr/bin/git` 2.54.0 and the
  login shell's PATH under Hardened Runtime, creates its own database.
