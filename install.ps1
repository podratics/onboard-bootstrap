# Podratic new-starter bootstrap (Windows / PowerShell).
#
# Usage:
#   irm https://raw.githubusercontent.com/podratics/onboard-bootstrap/master/install.ps1 | iex
#
# Requirements:
#   - PowerShell 5.1+ (PowerShell 7 recommended).
#   - An elevated (Administrator) PowerShell session. Chocolatey needs one to
#     install packages, and the onboard CLI refuses to run without one.
#
# Safety:
#   - `$ErrorActionPreference = 'Stop'` so any PowerShell error aborts the
#     script. It does not cover native exit codes, so `Invoke-Native` throws on
#     an unexpected one. Calls that branch on an exit code do so explicitly.
#   - Verifies podratics org membership before cloning any private code.
#   - Never writes secrets to disk; auth is delegated to `gh auth login`.

$ErrorActionPreference = 'Stop'

# ----- constants ------------------------------------------------------------

$Script:OnboardRepo = 'podratics/onboard'
$Script:OnboardOrg  = 'podratics'
$Script:WorkspaceDir = Join-Path $HOME 'workspace\podratic'
$Script:OnboardDir   = Join-Path $Script:WorkspaceDir 'onboard'

# ----- logging --------------------------------------------------------------

function Write-Info  { param([string]$Message) Write-Host "[onboard] $Message" -ForegroundColor Blue }
function Write-Ok    { param([string]$Message) Write-Host "[ ok   ] $Message" -ForegroundColor Green }
function Write-Err   { param([string]$Message) Write-Host "[error ] $Message" -ForegroundColor Red }
function Write-Step  { param([string]$Message) Write-Host "`n>>> $Message" -ForegroundColor DarkGray }

# ----- privilege check ------------------------------------------------------

# Returns $true if the current PowerShell session is running with
# Administrator rights. Chocolatey and the onboard CLI both need them.
function Test-IsAdmin {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ----- native command invocation --------------------------------------------

# Run a native executable and throw $FailureMessage if it exits with a code
# outside $AllowedExitCodes. PowerShell's $ErrorActionPreference does not apply
# to native exit codes, so a native failure is otherwise silent.
function Invoke-Native {
  param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [Parameter(Mandatory=$true)][string]$FailureMessage,
    [int[]]$AllowedExitCodes = @(0)
  )

  & $Executable @Arguments
  if ($AllowedExitCodes -notcontains $LASTEXITCODE) {
    throw "$FailureMessage (exit code $LASTEXITCODE)"
  }
}

# ----- PATH refresh ---------------------------------------------------------

# After installing a tool, the new shim is on the machine PATH but not in
# this process's environment. Pull the machine + user PATH into $env:Path so
# subsequent commands in this session can find the freshly installed tool.
function Update-SessionPath {
  $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machinePath;$userPath"
}

# ----- prerequisite installation -------------------------------------------

# Install Chocolatey if it is not already on PATH. `Invoke-Main` has already
# confirmed that this session has Administrator rights.
function Install-Chocolatey {
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Ok 'Chocolatey already installed'
    return
  }

  Write-Step 'Installing Chocolatey'
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::SecurityProtocol =
    [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
  Invoke-Expression (
    (New-Object System.Net.WebClient).DownloadString(
      'https://community.chocolatey.org/install.ps1'
    )
  )
  Update-SessionPath
}

# Install a package via Chocolatey unless the command is already available.
function Install-IfMissing {
  param(
    [Parameter(Mandatory=$true)][string]$Command,
    [Parameter(Mandatory=$true)][string]$ChocoPackage,
    [string]$DisplayName = $ChocoPackage
  )

  if (Get-Command $Command -ErrorAction SilentlyContinue) {
    Write-Ok "$DisplayName already installed"
    return
  }

  Write-Step "Installing $DisplayName"
  # Chocolatey reports a pending or initiated reboot with exit code 3010 or
  # 1641. The package still installed, so treat both as success.
  # https://docs.chocolatey.org/en-us/choco/commands/install
  Invoke-Native -Executable 'choco' -Arguments @('install', '-y', $ChocoPackage) `
    -AllowedExitCodes @(0, 1641, 3010) `
    -FailureMessage "Chocolatey failed to install $DisplayName."
  Update-SessionPath
}

# ----- GitHub auth + org gate ----------------------------------------------

# Run `gh auth login` if the user is not already authenticated. Always wire
# gh up as git's credential helper afterwards. GitHub requires a token for git
# operations. The helper supplies one, so `git pull` and `git push` in the
# cloned repo run without a prompt.
function Initialize-GhAuth {
  # A non-zero exit code here means the user has not authenticated yet.
  # This call branches on the exit code rather than throwing.
  & gh auth status 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $login = (& gh api user --jq .login).Trim()
    Write-Ok "GitHub CLI already authenticated as $login"
  } else {
    Write-Step 'Authenticating with GitHub (device flow via browser)'
    # Scopes:
    #   read:org         verify podratics org membership (the access gate)
    #   repo             clone private podratics repos
    #   workflow         common engineering tasks (gh workflow run, etc.)
    #   admin:public_key upload the operator's SSH public key from git-identity step
    Invoke-Native -Executable 'gh' -Arguments @(
      'auth', 'login',
      '--hostname', 'github.com',
      '--git-protocol', 'https',
      '--scopes', 'read:org,repo,workflow,admin:public_key',
      '--web'
    ) -FailureMessage 'gh auth login failed.'
  }

  # Idempotent: configures git's credential.helper for github.com to use gh.
  Invoke-Native -Executable 'gh' -Arguments @('auth', 'setup-git', '--hostname', 'github.com') `
    -FailureMessage 'gh auth setup-git failed.'
}

# Refuse to proceed unless the authenticated user is a member of the
# `podratics` GitHub organization. This is the access control gate.
function Confirm-OrgMembership {
  Write-Step 'Verifying podratics organization membership'
  $login = (& gh api user --jq .login).Trim()

  # A non-zero exit code here means the user is not a member.
  # This call branches on the exit code rather than throwing.
  & gh api -H 'Accept: application/vnd.github+json' "/orgs/$Script:OnboardOrg/members/$login" 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Ok "$login is a member of $Script:OnboardOrg"
    return
  }

  Write-Err "$login is not a member of the '$Script:OnboardOrg' GitHub org."
  Write-Err 'Ask whoever invited you to add you to the org first, then re-run.'
  exit 1
}

# ----- onboard handoff ------------------------------------------------------

# Clone (or update) the private onboard repo and invoke its Bun CLI.
function Invoke-OnboardCli {
  Write-Step "Cloning $Script:OnboardRepo"
  New-Item -ItemType Directory -Force -Path $Script:WorkspaceDir | Out-Null

  $gitDir = Join-Path $Script:OnboardDir '.git'
  if (Test-Path $gitDir) {
    Write-Ok "onboard already cloned at $Script:OnboardDir; pulling latest"
    Invoke-Native -Executable 'git' -Arguments @('-C', $Script:OnboardDir, 'checkout', 'master') `
      -FailureMessage 'Failed to check out the onboard master branch.'
    Invoke-Native -Executable 'git' -Arguments @('-C', $Script:OnboardDir, 'pull', '--ff-only') `
      -FailureMessage 'Failed to pull the latest onboard master.'
  } else {
    Invoke-Native -Executable 'gh' -Arguments @('repo', 'clone', $Script:OnboardRepo, $Script:OnboardDir) `
      -FailureMessage 'Failed to clone onboard.'
  }

  Write-Step 'Installing onboard CLI dependencies'
  Push-Location $Script:OnboardDir
  try {
    # Install runtime dependencies only. The CLI runs from source, so it needs
    # no development dependencies. Some of those need credentials that the CLI
    # itself configures later in this run.
    Invoke-Native -Executable 'bun' -Arguments @('install', '--production') `
      -FailureMessage 'bun install failed.'

    Write-Step 'Handing off to onboard CLI'
    Invoke-Native -Executable 'bun' -Arguments @('run', 'start') `
      -FailureMessage 'onboard CLI exited with a non-zero status.'
  } finally {
    Pop-Location
  }
}

# ----- main -----------------------------------------------------------------

function Invoke-Main {
  Write-Info 'Podratic new-starter bootstrap starting'

  # Check for Administrator rights first. Chocolatey needs them to install
  # packages, and the onboard CLI exits immediately without them. Without this
  # check a machine that already has Chocolatey passes every gate here, then
  # fails at the handoff.
  if (-not (Test-IsAdmin)) {
    Write-Err 'This bootstrap needs an elevated PowerShell session.'
    Write-Err 'Right-click PowerShell -> Run as Administrator, then re-run this script.'
    exit 1
  }

  Install-Chocolatey
  Install-IfMissing -Command 'git' -ChocoPackage 'git' -DisplayName 'Git'
  Install-IfMissing -Command 'gh'  -ChocoPackage 'gh'  -DisplayName 'GitHub CLI'
  Install-IfMissing -Command 'bun' -ChocoPackage 'bun' -DisplayName 'Bun'

  Initialize-GhAuth
  Confirm-OrgMembership
  Invoke-OnboardCli

  Write-Ok 'Bootstrap complete.'
}

Invoke-Main
