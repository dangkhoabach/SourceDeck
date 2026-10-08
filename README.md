# DKB Source Control

A native macOS Git client for daily work on this Mac, replacing Sourcetree for
the things it is actually used for: seeing what changed, staging files and
hunks, reading diffs, committing, pushing and pulling, and reading history —
across every repository at once from one dashboard.

Three things set it apart from a general-purpose client:

- **Commit messages in the house format.** The composer builds the
  `+ Keyword +` / ` - detail` / `  + sub-detail` structure from
  `git-rule.md` byte for byte, previews exactly what will be sent and refuses
  a message that breaks the format or carries an AI attribution line.
- **A check before every commit.** Staged `.env` files, private keys,
  `Local.xcconfig` and API keys in added lines are listed before the commit
  goes through.
- **Every repository on one screen.** Which ones have changes, what is ahead
  or behind, fetch them all with one click.

Merge, rebase, conflict resolution and the commit graph are deliberately out
of scope for v1; the toolbar opens the repository in Sourcetree, Terminal or
VS Code when one of those is needed.

The full design — measurements, decisions and the phase-by-phase checklist —
is in [`docs/dkb-source-control-build-plan.md`](docs/dkb-source-control-build-plan.md).

## How it works

The app runs the `git` already on the Mac (`/usr/bin/git`) and parses its
machine-readable output; it does not embed its own Git. Your `.gitconfig`,
global ignore file, hooks and credential helper (`osxkeychain`) apply exactly
as they do in Terminal. git never prompts: missing credentials fail at once
with git's own message. Hooks get the `PATH` of your login shell, so a hook
that runs `node` from nvm works.

Nothing destructive happens without a confirmation, discarded untracked files
go to the Trash, and there is no force push, hard reset or `git clean`.

## Requirements

- macOS 14+.
- git 2.30 or later — the one that comes with Xcode or the Command Line Tools
  (`xcode-select --install`) is fine.

## Building

```bash
./scripts/create-signing-cert.sh   # once: self-signed identity → Local.xcconfig
open DKBSourceControlNative.xcodeproj
```

Swift 6 / SwiftUI. The `.xcodeproj` is committed (`project.pbxproj` and the
shared scheme); the app and test folders are synchronized groups, so new
source files need no project edit. `Local.xcconfig` — gitignored, just
`CODE_SIGN_IDENTITY` — is the project's base configuration, so the build fails
until that file exists. The self-signed certificate keeps the app's identity
stable across builds, which keeps a macOS folder-access grant (for a
repository on the Desktop or in Documents) from being asked again after every
rebuild.

`DKBSourceControlCore` is a headless Swift package (git process runner,
parsers, GRDB storage) with its own tests:

```bash
cd DKBSourceControlCore && swift test
```

The only third-party dependency is [GRDB](https://github.com/groue/GRDB.swift),
for the list of added repositories.
