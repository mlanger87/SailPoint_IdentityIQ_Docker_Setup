<#
.SYNOPSIS
    One-time setup of the IdentityIQ Docker environment.

.DESCRIPTION
    Checks prerequisites, creates .env and optionally runs the first
    build.

.EXAMPLE
    .\scripts\setup.ps1
    .\scripts\setup.ps1 -Build
#>
[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\env.ps1"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Write-Step  { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  [ok] $m"    -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "  [!]  $m"    -ForegroundColor Yellow }
function Write-Err2  { param($m) Write-Host "  [xx] $m"    -ForegroundColor Red }

Write-Step "Checking prerequisites"

# --- Docker ---------------------------------------------------------------
try {
    $dockerVersion = (docker version --format '{{.Server.Version}}' 2>$null)
    if (-not $dockerVersion) { throw "no response" }
    Write-Ok "Docker Engine $dockerVersion"
} catch {
    Write-Err2 "Docker is not reachable. Is Docker Desktop running?"
    exit 1
}

# --- Compose --------------------------------------------------------------
try {
    $composeVersion = (docker compose version --short 2>$null)
    Write-Ok "Docker Compose $composeVersion"
} catch {
    Write-Err2 "'docker compose' is not available."
    exit 1
}

# --- Memory ---------------------------------------------------------------
$memBytes = [int64](docker info --format '{{.MemTotal}}' 2>$null)
$memGB = [math]::Round($memBytes / 1GB, 1)
if ($memGB -lt 8) {
    Write-Warn2 "Docker has only $memGB GB RAM available. At least 8 GB recommended."
    Write-Warn2 "Adjust under: Docker Desktop > Settings > Resources"
} else {
    Write-Ok "Memory available to Docker: $memGB GB"
}

# --- Installation package -------------------------------------------------
Write-Step "Checking installation package"

$installerDir = Join-Path $ProjectRoot 'installer'
$package = Get-ChildItem -Path $installerDir -Filter '*.zip' -ErrorAction SilentlyContinue |
           Select-Object -First 1

if (-not $package) {
    Write-Err2 "No installation package found in installer\."
    Write-Host ""
    Write-Host "  Copy the SailPoint package there, e.g.:" -ForegroundColor Yellow
    Write-Host "      installer\SailPoint_identityiq-8.5_Software_Package.zip" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  The package is deliberately NOT checked in (see .gitignore):" -ForegroundColor Gray
    Write-Host "  it contains licensed software." -ForegroundColor Gray
    exit 1
}

$sizeMB = [math]::Round($package.Length / 1MB, 0)
Write-Ok "$($package.Name) ($sizeMB MB)"

# --- .env -----------------------------------------------------------------
Write-Step "Configuration"

$envFile     = Join-Path $ProjectRoot '.env'
$envExample  = Join-Path $ProjectRoot '.env.example'

if (Test-Path $envFile) {
    Write-Ok ".env already exists (left unchanged)"
} else {
    Copy-Item $envExample $envFile
    Write-Ok ".env created from .env.example"
    Write-Warn2 "The default passwords are for local development only."
}

# --- Ports ----------------------------------------------------------------
Write-Step "Checking ports"

# From .env with compose defaults - see scripts/env.ps1.
$ports = Get-PublishedPorts

$conflict = $false
foreach ($entry in $ports.GetEnumerator()) {
    $inUse = Get-NetTCPConnection -LocalPort $entry.Value -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        Write-Warn2 "Port $($entry.Value) ($($entry.Key)) is already in use - change it in .env if needed"
        $conflict = $true
    }
}
if (-not $conflict) { Write-Ok "All required ports are free" }

# --- Build ----------------------------------------------------------------
if ($Build -or $Start) {
    Write-Step "Building images"
    Write-Host "  The first build takes several minutes:" -ForegroundColor Gray
    Write-Host "  the WAR unpacks to about 1 GB in over 8,900 files." -ForegroundColor Gray
    Push-Location $ProjectRoot
    try {
        docker compose build
        if ($LASTEXITCODE -ne 0) { throw "Build failed" }
        Write-Ok "Images built"
    } finally {
        Pop-Location
    }
}

if ($Start) {
    Write-Step "Starting environment"
    Push-Location $ProjectRoot
    try {
        docker compose up -d
        if ($LASTEXITCODE -ne 0) { throw "Start failed" }
    } finally {
        Pop-Location
    }
    Write-Ok "Containers started"
}

# --- Summary --------------------------------------------------------------
Write-Step "Done"

if (-not $Start) {
    Write-Host ""
    Write-Host "  Next step:" -ForegroundColor White
    Write-Host "      docker compose up -d" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "  Available after start:" -ForegroundColor White
Write-Endpoints -Indent '      '
Write-Host ""
Write-Host "  The first start takes several minutes - the database is" -ForegroundColor Gray
Write-Host "  created and the base configuration imported." -ForegroundColor Gray
Write-Host "  Follow progress with:" -ForegroundColor Gray
Write-Host "      docker compose logs -f iiq-init" -ForegroundColor Cyan
Write-Host ""
