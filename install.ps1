# Podratic new-starter bootstrap (Windows / PowerShell).
#
# This script is intentionally minimal. Its only job is to get the new starter
# onto a known baseline (bun + gh, authenticated) and then hand off to the
# Bun/TypeScript CLI in `podratics/onboard` which does the actual setup work.
#
# Usage:
#   irm https://raw.githubusercontent.com/podratics/onboard-bootstrap/master/install.ps1 | iex
#
# Requirements:
#   - PowerShell 5.1+ (PowerShell 7 recommended).
#   - Administrator privileges are required to install Chocolatey itself.
#     Subsequent `choco install` calls will reuse the same elevated session.
#
# Safety:
#   - `$ErrorActionPreference = 'Stop'` so any failure aborts the script.
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
function Write-Warn  { param([string]$Message) Write-Host "[ warn ] $Message" -ForegroundColor Yellow }
function Write-Err   { param([string]$Message) Write-Host "[error ] $Message" -ForegroundColor Red }
function Write-Step  { param([string]$Message) Write-Host "`n>>> $Message" -ForegroundColor DarkGray }

# ----- privilege check ------------------------------------------------------

# Returns $true if the current PowerShell session is running with
# Administrator rights. Chocolatey installation requires this.
function Test-IsAdmin {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
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

# Install Chocolatey if it is not already on PATH. Requires Administrator.
function Install-Chocolatey {
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Ok 'Chocolatey already installed'
    return
  }

  if (-not (Test-IsAdmin)) {
    Write-Err 'Chocolatey install needs an elevated PowerShell session.'
    Write-Err 'Right-click PowerShell -> Run as Administrator, then re-run this script.'
    exit 1
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
  choco install -y $ChocoPackage
  Update-SessionPath
}

# ----- GitHub auth + org gate ----------------------------------------------

# Run `gh auth login` if the user is not already authenticated.
function Initialize-GhAuth {
  $status = & gh auth status 2>&1
  if ($LASTEXITCODE -eq 0) {
    $login = (& gh api user --jq .login).Trim()
    Write-Ok "GitHub CLI already authenticated as $login"
    return
  }

  Write-Step 'Authenticating with GitHub (device flow via browser)'
  # `read:org` is required so we can verify org membership against podratics.
  & gh auth login `
    --hostname github.com `
    --git-protocol https `
    --scopes 'read:org,repo,workflow' `
    --web
  if ($LASTEXITCODE -ne 0) {
    throw 'gh auth login failed.'
  }
}

# Refuse to proceed unless the authenticated user is a member of the
# `podratics` GitHub organization. This is the access control gate.
function Confirm-OrgMembership {
  Write-Step 'Verifying podratics organization membership'
  $login = (& gh api user --jq .login).Trim()

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
    & git -C $Script:OnboardDir pull --ff-only
  } else {
    & gh repo clone $Script:OnboardRepo $Script:OnboardDir
  }
  if ($LASTEXITCODE -ne 0) { throw 'Failed to clone or update onboard.' }

  Write-Step 'Installing onboard CLI dependencies'
  Push-Location $Script:OnboardDir
  try {
    & bun install
    if ($LASTEXITCODE -ne 0) { throw 'bun install failed.' }

    Write-Step 'Handing off to onboard CLI'
    & bun run start
    if ($LASTEXITCODE -ne 0) { throw 'onboard CLI exited with a non-zero status.' }
  } finally {
    Pop-Location
  }
}

# ----- main -----------------------------------------------------------------

function Invoke-Main {
  Write-Info 'Podratic new-starter bootstrap starting'

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
