# Security policy

## Reporting a vulnerability

Please report security issues privately, not in a public issue:

- **GitHub:** Security tab → **Report a vulnerability** on this repository, or
- **Contact form** on [dangkhoabach.vn](https://dangkhoabach.vn), asking for a private channel.

Include the app version (Settings), your macOS version, your git version and the steps to
reproduce. You will get a reply within a week. Please give a fix the chance to ship before you
disclose the issue publicly.

## Supported versions

Only the latest release gets security fixes. It reaches you through **Check for Updates…**.

## Scope

In scope:

- **Credentials:** an account typed into Sign In reaching anything other than git's credential
  helper, appearing in the operation log, or being kept by the app.
- **Repository content:** a crafted repository (file names, refs, commit messages, diffs,
  `.gitignore`, hooks it does not already run in Terminal) that makes the app run a command or
  write outside that repository.
- **Data loss:** a path that deletes files without the confirmation that names them, force
  pushes, runs `git clean` or a hard reset without stashing first.
- **The sensitive check:** a staged secret file or key format that it is documented to catch
  but lets through.
- **Updates:** installing an update that is not signed with the release key.

Out of scope:

- What git itself, your hooks or your credential helper do; the app runs them as Terminal would.
- A Mac that is already compromised, or someone using it while it is unlocked.
