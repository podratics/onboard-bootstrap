# onboard-bootstrap

The tiny public entry point for setting up a Podratic engineering workstation.

This repo exists for one reason: to give new starters a single-line install
command they can run on a fresh machine. Everything else - the real setup
logic, the editor configuration, the Claude Code defaults, the cloned repos -
lives in the private [`podratics/onboard`](https://github.com/podratics/onboard)
repository.

## Quick start

### macOS / Linux (Ubuntu, Debian, Arch)

```bash
curl -fsSL https://raw.githubusercontent.com/podratics/onboard-bootstrap/master/install.sh | bash
```

### Windows (PowerShell, Administrator)

Open **PowerShell as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/podratics/onboard-bootstrap/master/install.ps1 | iex
```

You will be prompted to authenticate with GitHub in your browser. The
bootstrap will refuse to continue unless you are a member of the
`podratics` GitHub organization.

## What the bootstrap does

The bootstrap is intentionally short. It only handles the steps you cannot
take from inside a Bun/TypeScript program because Bun is not yet installed:

1. Detect the OS (macOS, Ubuntu/Debian, Arch, or Windows).
2. Install the platform package manager if missing (Homebrew on macOS,
   Chocolatey on Windows). On Linux, `apt` or `pacman` is assumed present.
3. Install `git`, the GitHub CLI (`gh`), and `bun`.
4. Run `gh auth login` against your GitHub account (browser device flow).
5. Verify your account is a member of the `podratics` organization.
6. Clone `podratics/onboard` to `~/workspace/podratic/onboard`.
7. Run `bun install` and `bun run start`, handing off to the real setup CLI.

Everything beyond step 7 - VS Code, fonts, Claude Code, SSH keys, repo
clones, etc - is handled inside the private CLI, which can be developed and
audited in TypeScript like any other Podratic project.

## Why is this repo public?

The repo is public because the install command in this README needs to be
fetched without authentication. No secrets live in this repo. Access control
to the actual setup logic happens at step 5: only `podratics` org members can
clone the private `onboard` repository.

## Supported platforms

| Platform        | Package manager | Notes |
| --------------- | --------------- | ----- |
| macOS           | Homebrew        | Apple Silicon and Intel both supported |
| Ubuntu / Debian | apt             | Includes Pop!_OS, Mint, and other Debian-derived distros |
| Arch / Manjaro  | pacman          | |
| Windows 10/11   | Chocolatey      | Requires elevated PowerShell |

Other Linux distributions are not yet supported. PRs to add Fedora (`dnf`)
or openSUSE (`zypper`) support are welcome - see `install.sh` for the
per-distro pattern.

## Security model

- The bootstrap script is small and auditable. Read it before piping it
  into your shell if you have any doubt.
- The bootstrap never accepts a long-lived token from the user. All
  authentication is delegated to `gh auth login`, which uses GitHub's
  device flow against a browser session.
- The bootstrap verifies podratics org membership via `/orgs/podratics/
  members/{user}` before cloning any private code. A non-member cannot
  reach the private onboard repository regardless of what they do here.
- Both this repo and `podratics/onboard` enforce branch protection on
  `master`, so the install command always fetches reviewed code.

## Releases

This repo does not version itself; `master` is the source of truth and the
install URL above always points to it. If you need to pin a specific commit,
replace `master` in the URL with the commit SHA.

## License

MIT - see [LICENSE](./LICENSE).
