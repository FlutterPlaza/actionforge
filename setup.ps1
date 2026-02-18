# ============================================================================
#  ActionForge — One-Click Self-Hosted CI Runners
#  A FlutterPlaza Open-Source Product | https://flutterplaza.com
# ============================================================================
#  Usage:
#    actionforge                   # Interactive mode (prompts for everything)
#    actionforge -Mode docker      # Use Docker-based isolated runner
#    actionforge -Mode bare        # Install runner directly on this machine
#    actionforge -Mode teardown    # Remove all runners from this machine
#
#  Environment variables (optional — skips prompts):
#    GH_ORG          GitHub org or user           (e.g. "my-company")
#    GH_REPO         Specific repo (optional)     (e.g. "backend-api")
#    GH_PAT          Personal Access Token
#    RUNNER_COUNT    Number of parallel runners   (default: 2)
#    RUNNER_LABELS   Comma-separated labels       (default: auto-detected)
#
#  Supported: Windows 10+ with PowerShell 5.1+
# ============================================================================

param(
    [ValidateSet("docker", "bare", "teardown", "")]
    [string]$Mode = ""
)

$ErrorActionPreference = "Stop"

# ── Config ───────────────────────────────────────────────────────────────────
$RunnerVersion = "2.321.0"
$RunnerArch    = "x64"
$ConfigFile    = Join-Path $env:USERPROFILE ".actionforge.conf"

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Info    { param([string]$Msg) Write-Host "  i  $Msg" -ForegroundColor Blue }
function Write-Ok      { param([string]$Msg) Write-Host "  +  $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "  !  $Msg" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Msg) Write-Host "  x  $Msg" -ForegroundColor Red; exit 1 }

function Show-Banner {
    Write-Host ""
    Write-Host "  +===================================================+" -ForegroundColor Cyan
    Write-Host "  |       ActionForge -- by FlutterPlaza              |" -ForegroundColor Cyan
    Write-Host "  |       One-Click Self-Hosted CI Runners            |" -ForegroundColor Cyan
    Write-Host "  +===================================================+" -ForegroundColor Cyan
    Write-Host ""
}

# ── Detect package manager ─────────────────────────────────────────────────
function Get-PkgManager {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return "winget" }
    if (Get-Command choco -ErrorAction SilentlyContinue)  { return "choco" }
    return $null
}

function Install-WithPkgManager {
    param(
        [string]$WingetId,
        [string]$ChocoName,
        [string]$DisplayName
    )

    $mgr = Get-PkgManager
    if ($mgr -eq "winget") {
        Write-Info "Installing $DisplayName via winget..."
        winget install --id $WingetId --accept-source-agreements --accept-package-agreements --silent
    } elseif ($mgr -eq "choco") {
        Write-Info "Installing $DisplayName via Chocolatey..."
        choco install $ChocoName -y
    } else {
        Write-Fail "No package manager found (winget or chocolatey). Please install $DisplayName manually."
    }
}

# ── Install prerequisites ──────────────────────────────────────────────────
function Install-Prerequisites {
    # Git
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Install-WithPkgManager -WingetId "Git.Git" -ChocoName "git" -DisplayName "Git"
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    }

    # curl (built into Windows 10+, but check)
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        Install-WithPkgManager -WingetId "cURL.cURL" -ChocoName "curl" -DisplayName "curl"
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    }

    # jq
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        Install-WithPkgManager -WingetId "jqlang.jq" -ChocoName "jq" -DisplayName "jq"
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    }

    Write-Ok "Basic prerequisites satisfied (git, curl, jq)"
}

# ── Install Docker Desktop ────────────────────────────────────────────────
function Install-Docker {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        # Verify daemon is running
        $null = docker info 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Docker is already installed and running"
            return
        }
        Write-Warn "Docker is installed but the daemon is not running. Starting Docker Desktop..."
        Start-Process "Docker Desktop" -ErrorAction SilentlyContinue
    } else {
        Write-Info "Docker not found -- installing Docker Desktop..."
        Install-WithPkgManager -WingetId "Docker.DockerDesktop" -ChocoName "docker-desktop" -DisplayName "Docker Desktop"
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        Write-Info "Starting Docker Desktop..."
        Start-Process "Docker Desktop" -ErrorAction SilentlyContinue
    }

    # Wait for Docker daemon
    Write-Info "Waiting for Docker daemon to start (up to 90s)..."
    $waited = 0
    while ($waited -lt 90) {
        $null = docker info 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 3
        $waited += 3
    }

    $null = docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Docker daemon did not start within 90s. Please start Docker Desktop manually and re-run this script."
    }

    # Verify docker compose
    $null = docker compose version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Docker Compose is not available. Please ensure Docker Desktop is up to date."
    }

    Write-Ok "Docker Desktop is running with Compose support"
}

# ── Prompt for configuration ──────────────────────────────────────────────
function Get-RunnerConfig {
    # Load saved config
    if (Test-Path $ConfigFile) {
        Get-Content $ConfigFile | ForEach-Object {
            if ($_ -match '^(\w+)=(.*)$') {
                Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script
            }
        }
    }

    if (-not $script:GH_ORG) {
        $script:GH_ORG = Read-Host "GitHub org or username"
    }

    if (-not $script:GH_REPO) {
        $script:GH_REPO = Read-Host "Specific repo (leave blank for org-wide)"
    }

    if (-not $script:GH_PAT) {
        Write-Host "You need a PAT with these scopes:" -ForegroundColor Yellow
        Write-Host "  - repo (full control)"
        Write-Host "  - admin:org -> manage_runners:org  (if org-wide)"
        Write-Host ""
        $secPat = Read-Host "GitHub Personal Access Token" -AsSecureString
        $script:GH_PAT = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPat)
        )
    }

    if (-not $script:RUNNER_COUNT) { $script:RUNNER_COUNT = "2" }
    $inputCount = Read-Host "Number of parallel runners [$($script:RUNNER_COUNT)]"
    if ($inputCount) { $script:RUNNER_COUNT = $inputCount }

    if (-not $script:RUNNER_LABELS) {
        $script:RUNNER_LABELS = "windows-latest,windows-2022,self-hosted,windows,x64"
    }

    # Save config (except PAT)
    @(
        "GH_ORG=$($script:GH_ORG)",
        "GH_REPO=$($script:GH_REPO)",
        "RUNNER_COUNT=$($script:RUNNER_COUNT)",
        "RUNNER_LABELS=$($script:RUNNER_LABELS)"
    ) | Set-Content $ConfigFile
    Write-Ok "Config saved to $ConfigFile"
}

# ── Resolve GitHub API URL ────────────────────────────────────────────────
function Resolve-Urls {
    if ($script:GH_REPO) {
        $script:API_URL    = "https://api.github.com/repos/$($script:GH_ORG)/$($script:GH_REPO)/actions/runners/registration-token"
        $script:CONFIG_URL = "https://github.com/$($script:GH_ORG)/$($script:GH_REPO)"
        $script:SCOPE      = "repo: $($script:GH_ORG)/$($script:GH_REPO)"
    } else {
        $script:API_URL    = "https://api.github.com/orgs/$($script:GH_ORG)/actions/runners/registration-token"
        $script:CONFIG_URL = "https://github.com/$($script:GH_ORG)"
        $script:SCOPE      = "org: $($script:GH_ORG)"
    }
    Write-Info "Scope: $($script:SCOPE)"
}

# ── Get registration token ────────────────────────────────────────────────
function Get-RegToken {
    $headers = @{
        "Authorization" = "Bearer $($script:GH_PAT)"
        "Accept"        = "application/vnd.github+json"
    }
    try {
        $response = Invoke-RestMethod -Uri $script:API_URL -Method Post -Headers $headers
        $script:REG_TOKEN = $response.token
    } catch {
        Write-Fail "Failed to get registration token. Check your PAT scopes. Error: $_"
    }
    if (-not $script:REG_TOKEN) {
        Write-Fail "Failed to get registration token. Check your PAT scopes."
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  DOCKER-BASED INSTALL
# ══════════════════════════════════════════════════════════════════════════════
function Install-DockerMode {
    $kitDir = Split-Path -Parent $MyInvocation.ScriptName
    if (-not $kitDir) { $kitDir = $PSScriptRoot }

    $envFile = Join-Path $kitDir ".env"
    @(
        "GH_ORG=$($script:GH_ORG)",
        "GH_REPO=$($script:GH_REPO)",
        "GH_PAT=$($script:GH_PAT)",
        "RUNNER_LABELS=$($script:RUNNER_LABELS)",
        "RUNNER_COUNT=$($script:RUNNER_COUNT)"
    ) | Set-Content $envFile

    Push-Location $kitDir
    try {
        Write-Info "Building runner image..."
        docker compose build
        if ($LASTEXITCODE -ne 0) { Write-Fail "Docker build failed." }

        Write-Info "Starting $($script:RUNNER_COUNT) runners..."
        docker compose up -d --scale runner=$($script:RUNNER_COUNT)
        if ($LASTEXITCODE -ne 0) { Write-Fail "Docker compose up failed." }

        Write-Ok "Runners are live! Check status with: docker compose ps"
    } finally {
        Pop-Location
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  BARE METAL INSTALL
# ══════════════════════════════════════════════════════════════════════════════
function Install-BareMode {
    $runnerBase = Join-Path $env:USERPROFILE "actions-runners"
    if (-not (Test-Path $runnerBase)) { New-Item -ItemType Directory -Path $runnerBase | Out-Null }

    $runnerPackage = "actions-runner-win-x64-$RunnerVersion.zip"

    for ($i = 1; $i -le [int]$script:RUNNER_COUNT; $i++) {
        $runnerDir = Join-Path $runnerBase "runner-$i"
        Write-Info "Setting up runner-$i of $($script:RUNNER_COUNT)..."

        if (-not (Test-Path $runnerDir)) { New-Item -ItemType Directory -Path $runnerDir | Out-Null }

        # Download if not already present
        $configCmd = Join-Path $runnerDir "config.cmd"
        if (-not (Test-Path $configCmd)) {
            $zipPath = Join-Path $runnerDir "runner.zip"
            $downloadUrl = "https://github.com/actions/runner/releases/download/v$RunnerVersion/$runnerPackage"
            Write-Info "Downloading runner package..."
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $runnerDir -Force
            Remove-Item $zipPath
        }

        # Get a fresh registration token
        Get-RegToken

        # Configure
        Push-Location $runnerDir
        try {
            & .\config.cmd `
                --url $script:CONFIG_URL `
                --token $script:REG_TOKEN `
                --name "$($env:COMPUTERNAME)-runner-$i" `
                --labels $script:RUNNER_LABELS `
                --work "_work" `
                --replace `
                --unattended `
                --runasservice
        } finally {
            Pop-Location
        }

        Write-Ok "runner-$i is live and listening for jobs"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  TEARDOWN
# ══════════════════════════════════════════════════════════════════════════════
function Invoke-Teardown {
    Write-Warn "Tearing down all runners on this machine..."

    # Docker runners
    $kitDir = Split-Path -Parent $MyInvocation.ScriptName
    if (-not $kitDir) { $kitDir = $PSScriptRoot }

    $composeFile = Join-Path $kitDir "docker-compose.yml"
    if (Test-Path $composeFile) {
        Push-Location $kitDir
        try {
            docker compose down 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Docker runners stopped" }
        } catch { }
        finally { Pop-Location }
    }

    # Bare-metal runners
    $runnerBase = Join-Path $env:USERPROFILE "actions-runners"
    if (Test-Path $runnerBase) {
        Get-ChildItem -Path $runnerBase -Directory -Filter "runner-*" | ForEach-Object {
            $dir = $_.FullName
            Write-Info "Removing $($_.Name)..."

            Push-Location $dir
            try {
                # Stop and remove Windows service
                $svcName = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue |
                    Where-Object { $_.BinaryPathName -like "*$dir*" } |
                    Select-Object -First 1 -ExpandProperty Name
                if ($svcName) {
                    Stop-Service $svcName -Force -ErrorAction SilentlyContinue
                    & sc.exe delete $svcName 2>$null
                }

                # Deregister from GitHub
                Get-RegToken
                & .\config.cmd remove --token $script:REG_TOKEN 2>$null
            } catch { }
            finally { Pop-Location }
        }

        Remove-Item -Recurse -Force $runnerBase
        Write-Ok "Bare-metal runners removed"
    }

    if (Test-Path $ConfigFile) { Remove-Item $ConfigFile }
    $envFile = Join-Path $kitDir ".env"
    if (Test-Path $envFile) { Remove-Item $envFile }
    Write-Ok "Teardown complete"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
function Main {
    Show-Banner
    Write-Info "Detected: Windows/$RunnerArch"

    # Interactive mode selection if not specified
    if (-not $Mode) {
        Write-Host "How would you like to run the CI runners?"
        Write-Host ""
        Write-Host "  1) Docker (recommended) -- each job runs in an isolated container"
        Write-Host "  2) Bare metal            -- runner installs directly on this machine"
        Write-Host "  3) Teardown              -- remove all runners from this machine"
        Write-Host ""
        $choice = Read-Host "Choose [1/2/3]"
        switch ($choice) {
            "1" { $Mode = "docker" }
            "2" { $Mode = "bare" }
            "3" { $Mode = "teardown" }
            default { Write-Fail "Invalid choice" }
        }
    }

    Get-RunnerConfig
    Resolve-Urls

    if ($Mode -eq "teardown") {
        Invoke-Teardown
        return
    }

    Install-Prerequisites

    if ($Mode -eq "docker") {
        Install-Docker
    }

    Write-Host ""
    Write-Info "Mode:    $Mode"
    Write-Info "Scope:   $($script:SCOPE)"
    Write-Info "Runners: $($script:RUNNER_COUNT)"
    Write-Info "Labels:  $($script:RUNNER_LABELS)"
    Write-Host ""
    $confirm = Read-Host "Proceed? [Y/n]"
    if ($confirm -and $confirm -notmatch '^[Yy]$') { return }

    switch ($Mode) {
        "docker" { Install-DockerMode }
        "bare"   { Install-BareMode }
    }

    Write-Host ""
    Write-Host "  +===================================================+" -ForegroundColor Green
    Write-Host "  |              Setup Complete!                       |" -ForegroundColor Green
    Write-Host "  +===================================================+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  $($script:RUNNER_COUNT) runners are now listening for jobs."
    Write-Host ""
    Write-Host "  Your existing workflows need ZERO changes."
    Write-Host "  Any workflow with 'runs-on: windows-latest' will"
    Write-Host "  automatically route to these local runners."
    Write-Host ""
    Write-Host "  Useful commands:"
    if ($Mode -eq "docker") {
        Write-Host "    docker compose ps          -- check runner status"
        Write-Host "    docker compose logs -f     -- watch runner logs"
        Write-Host "    docker compose down        -- stop runners"
        Write-Host "    actionforge -Mode teardown   -- full cleanup"
    } else {
        Write-Host "    Get-Service actions.runner.* -- check runner status"
        Write-Host "    actionforge -Mode teardown   -- full cleanup"
    }
    Write-Host ""
}

Main
