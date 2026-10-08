# Releasing DKB Source Control (native, macOS)

Everything runs locally on this Mac — no CI, no GitHub Releases, no update
server. v1 is built and installed here only (plan D19): there is no Sparkle,
no appcast and no public DMG. Those come with the backlog item that puts the
app on dangkhoabach.vn, and that is also when signing should be looked at
again for other Macs.

## Why a self-signed certificate

No Apple Developer Program membership, so no Developer ID signing and no
notarization. Builds are signed with the self-signed **"DKB Source Control
Local Signing"** certificate from `scripts/create-signing-cert.sh` (named in
the gitignored `Local.xcconfig`) rather than ad-hoc (plan D1):

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
2. **`create-dmg`** — `brew install create-dmg` (styles the installer's Finder
   window with an Applications drop link).

## Cutting a release

```bash
./scripts/release.sh 1.0.1      # or without a version: it asks, Enter keeps the current one
```

The version goes into both `CFBundleShortVersionString` and
`CFBundleVersion` in `DKBSourceControlApp/Info.plist` (a lower version than
the current one is refused). Then, in order:

1. `swift test` for `DKBSourceControlCore`, then the app's tests — a failure
   stops the release before anything is built.
2. Release build with the local certificate, universal (arm64 + x86_64), in a
   temporary DerivedData folder that is removed afterwards.
3. Checks on the built app: signature valid, signed by the local certificate,
   Hardened Runtime on, **no entitlements at all** (no sandbox, nothing
   relaxed, no `get-task-allow`), both architectures, the version just set.
4. DMG with `create-dmg`, and its SHA-256 next to it.

If any step fails, `Info.plist` is put back as it was. Output lands in
`release-output/<version>/` (gitignored): the `.dmg`, its `.sha256` and the
`.app`.

Commit the version bump in `Info.plist` and tag the release only when it is
decided to keep it (git-rule: commits and tags are made on request).

## Installing on this Mac

```bash
./scripts/install-local.sh          # newest release in release-output/
./scripts/install-local.sh 1.0.0
```

Quits the running app, replaces `/Applications/DKB Source Control.app` and
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
- `DKB-Source-Control-1.0.0.dmg`: 5.2 MB, SHA-256
  `9476feed1b5573b28d6dd315b52d940c0bcb9871ee980ebe7e32cee1be4f1171`; the app
  is 18 MB.
- Installed to `/Applications`: starts, finds `/usr/bin/git` 2.54.0 and the
  login shell's PATH under Hardened Runtime, creates its own database.
