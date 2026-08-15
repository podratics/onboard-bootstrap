#!/usr/bin/env bash
#
# Podratic new-starter bootstrap (macOS and Linux).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/podratics/onboard-bootstrap/master/install.sh | bash
#
# Supported platforms:
#   - macOS (Homebrew)
#   - Ubuntu / Debian (apt)
#   - Arch / Manjaro (pacman)
#
# Safety:
#   - `set -euo pipefail`, so any failure stops the script.
#   - The script verifies podratics org membership before it clones private code.
#   - The script writes no secrets to disk. `gh auth login` handles authentication.

set -euo pipefail

# ----- constants ------------------------------------------------------------

readonly ONBOARD_REPO="podratics/onboard"
readonly ONBOARD_ORG="podratics"
readonly WORKSPACE_DIR="${HOME}/workspace/podratic"
readonly ONBOARD_DIR="${WORKSPACE_DIR}/onboard"

# ----- logging --------------------------------------------------------------

# ANSI escapes, set only when stdout is a TTY. Piped output stays plain.
if [ -t 1 ]; then
  readonly C_BLUE=$'\033[34m'
  readonly C_GREEN=$'\033[32m'
  readonly C_RED=$'\033[31m'
  readonly C_DIM=$'\033[2m'
  readonly C_RESET=$'\033[0m'
else
  readonly C_BLUE=""
  readonly C_GREEN=""
  readonly C_RED=""
  readonly C_DIM=""
  readonly C_RESET=""
fi

log_info()  { printf "%s[onboard]%s %s\n" "${C_BLUE}"   "${C_RESET}" "$*"; }
log_ok()    { printf "%s[ ok   ]%s %s\n" "${C_GREEN}"  "${C_RESET}" "$*"; }
log_error() { printf "%s[error ]%s %s\n" "${C_RED}"    "${C_RESET}" "$*" >&2; }
log_step()  { printf "\n%s>>>%s %s\n" "${C_DIM}" "${C_RESET}" "$*"; }

die() { log_error "$*"; exit 1; }

# ----- platform detection ---------------------------------------------------

# Sets the global PLATFORM_KIND to one of:
#   macos | linux-debian | linux-arch
detect_platform() {
  local uname_s
  uname_s="$(uname -s)"

  case "${uname_s}" in
    Darwin)
      PLATFORM_KIND="macos"
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        PLATFORM_KIND="linux-debian"
      elif command -v pacman >/dev/null 2>&1; then
        PLATFORM_KIND="linux-arch"
      else
        die "Unsupported Linux distribution. Supported: Ubuntu/Debian (apt), Arch (pacman)."
      fi
      ;;
    *)
      die "Unsupported operating system: ${uname_s}. Use install.ps1 on Windows."
      ;;
  esac

  log_ok "Detected platform: ${PLATFORM_KIND}"
}

# ----- prerequisite installation -------------------------------------------

# Install Homebrew on macOS if it is absent. A Linux distribution already has apt or pacman.
ensure_platform_package_manager() {
  if [ "${PLATFORM_KIND}" != "macos" ]; then
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    log_ok "Homebrew already installed"
    return 0
  fi

  log_step "Installing Homebrew"
  # The official Homebrew installer, run from its own URL.
  /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Homebrew installs to /opt/homebrew on Apple Silicon and to /usr/local on Intel. The current
  # shell does not have it on PATH yet.
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# Install the GitHub CLI for the current platform.
ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    log_ok "GitHub CLI already installed ($(gh --version | head -1))"
    return 0
  fi

  log_step "Installing GitHub CLI"
  case "${PLATFORM_KIND}" in
    macos)
      brew install gh
      ;;
    linux-debian)
      # https://github.com/cli/cli/blob/trunk/docs/install_linux.md
      sudo apt-get update -y
      sudo apt-get install -y curl ca-certificates
      sudo install -dm 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      sudo chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
      printf "deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n" \
        "$(dpkg --print-architecture)" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      sudo apt-get update -y
      sudo apt-get install -y gh
      ;;
    linux-arch)
      sudo pacman -Sy --noconfirm github-cli
      ;;
  esac
}

# Install Bun for the current platform.
ensure_bun() {
  if command -v bun >/dev/null 2>&1; then
    log_ok "Bun already installed ($(bun --version))"
    return 0
  fi

  log_step "Installing Bun"
  case "${PLATFORM_KIND}" in
    macos)
      brew install oven-sh/bun/bun
      ;;
    linux-debian|linux-arch)
      # The official Bun installer puts the binary in ~/.bun/bin.
      sudo apt-get install -y unzip 2>/dev/null || sudo pacman -Sy --noconfirm unzip 2>/dev/null || true
      curl -fsSL https://bun.sh/install | bash
      export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
      export PATH="${BUN_INSTALL}/bin:${PATH}"
      ;;
  esac
}

# Install git if it is absent. On macOS the Xcode Command Line Tools installer prompts for it. On
# Linux this script installs it.
ensure_git() {
  if command -v git >/dev/null 2>&1; then
    log_ok "git already installed ($(git --version))"
    return 0
  fi

  log_step "Installing git"
  case "${PLATFORM_KIND}" in
    macos)
      # Triggers the Xcode Command Line Tools installer dialog.
      xcode-select --install || true
      die "Re-run this script after the Xcode Command Line Tools install completes."
      ;;
    linux-debian)
      sudo apt-get install -y git
      ;;
    linux-arch)
      sudo pacman -Sy --noconfirm git
      ;;
  esac
}

# ----- GitHub auth + org gate ----------------------------------------------

# Run `gh auth login` if the user is not authenticated yet, then always set gh as git's credential
# helper. GitHub requires a token for a git operation. The helper supplies one, so `git pull` and
# `git push` in the cloned repo run without a prompt.
ensure_gh_auth() {
  if gh auth status >/dev/null 2>&1; then
    log_ok "GitHub CLI already authenticated as $(gh api user --jq .login)"
  else
    log_step "Authenticating with GitHub (device flow via browser)"
    # Scopes:
    #   read:org         verify podratics org membership (the access gate)
    #   repo             clone private podratics repos
    #   workflow         common engineering tasks (gh workflow run, etc.)
    #   admin:public_key upload the operator's SSH public key from git-identity step
    gh auth login \
      --hostname github.com \
      --git-protocol https \
      --scopes "read:org,repo,workflow,admin:public_key" \
      --web
  fi

  # This command is idempotent. It sets git's credential.helper for github.com to gh.
  gh auth setup-git --hostname github.com
}

# Stop unless the authenticated user is a member of the `podratics` GitHub organization. This check
# is the access gate: a person outside the organization cannot clone the private onboard repository.
verify_org_membership() {
  log_step "Verifying podratics organization membership"
  local login
  login="$(gh api user --jq .login)"

  if gh api -H "Accept: application/vnd.github+json" \
       "/orgs/${ONBOARD_ORG}/members/${login}" >/dev/null 2>&1; then
    log_ok "${login} is a member of ${ONBOARD_ORG}"
    return 0
  fi

  log_error "${login} is not a member of the '${ONBOARD_ORG}' GitHub org."
  log_error "Ask whoever invited you to add you to the org first, then re-run."
  exit 1
}

# ----- onboard handoff ------------------------------------------------------

# Clone (or update) the private onboard repo and invoke its Bun CLI.
clone_and_run_onboard() {
  log_step "Cloning ${ONBOARD_REPO}"
  mkdir -p "${WORKSPACE_DIR}"

  if [ -d "${ONBOARD_DIR}/.git" ]; then
    log_ok "onboard already cloned at ${ONBOARD_DIR}; pulling latest"
    git -C "${ONBOARD_DIR}" checkout master
    git -C "${ONBOARD_DIR}" pull --ff-only
  else
    gh repo clone "${ONBOARD_REPO}" "${ONBOARD_DIR}"
  fi

  log_step "Installing onboard CLI dependencies"
  # Install runtime dependencies only. The CLI runs from source, so it needs no development
  # dependencies. Some of those need credentials that the CLI configures later in this run.
  ( cd "${ONBOARD_DIR}" && bun install --production )

  log_step "Handing off to onboard CLI"
  # Redirect stdin from /dev/tty so the onboard CLI's prompts work. A `curl ... | bash` invocation
  # leaves stdin attached to the curl pipe, which is not a TTY. A raw-mode keystroke reader such as
  # the `prompts` library then fails.
  ( cd "${ONBOARD_DIR}" && bun run start < /dev/tty )
}

# ----- main -----------------------------------------------------------------

main() {
  log_info "Podratic new-starter bootstrap starting"
  detect_platform
  ensure_platform_package_manager
  ensure_git
  ensure_gh
  ensure_bun
  ensure_gh_auth
  verify_org_membership
  clone_and_run_onboard
  log_ok "Bootstrap complete."
}

main "$@"
