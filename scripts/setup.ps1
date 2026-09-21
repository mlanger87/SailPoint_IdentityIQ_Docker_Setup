<#
.SYNOPSIS
    Einmaliges Einrichten der IdentityIQ-Docker-Umgebung.

.DESCRIPTION
    Prueft die Voraussetzungen, legt die .env an und startet optional
    den ersten Build.

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
$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Write-Step  { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  [ok] $m"    -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "  [!]  $m"    -ForegroundColor Yellow }
function Write-Err2  { param($m) Write-Host "  [xx] $m"    -ForegroundColor Red }

Write-Step "Voraussetzungen pruefen"

# --- Docker ---------------------------------------------------------------
try {
    $dockerVersion = (docker version --format '{{.Server.Version}}' 2>$null)
    if (-not $dockerVersion) { throw "keine Antwort" }
    Write-Ok "Docker Engine $dockerVersion"
} catch {
    Write-Err2 "Docker ist nicht erreichbar. Laeuft Docker Desktop?"
    exit 1
}

# --- Compose --------------------------------------------------------------
try {
    $composeVersion = (docker compose version --short 2>$null)
    Write-Ok "Docker Compose $composeVersion"
} catch {
    Write-Err2 "'docker compose' steht nicht zur Verfuegung."
    exit 1
}

# --- Arbeitsspeicher ------------------------------------------------------
$memBytes = [int64](docker info --format '{{.MemTotal}}' 2>$null)
$memGB = [math]::Round($memBytes / 1GB, 1)
if ($memGB -lt 8) {
    Write-Warn2 "Docker stehen nur $memGB GB RAM zur Verfuegung. Empfohlen sind mindestens 8 GB."
    Write-Warn2 "Einstellbar unter: Docker Desktop > Settings > Resources"
} else {
    Write-Ok "Arbeitsspeicher fuer Docker: $memGB GB"
}

# --- Installationspaket ---------------------------------------------------
Write-Step "Installationspaket pruefen"

$installerDir = Join-Path $ProjectRoot 'installer'
$package = Get-ChildItem -Path $installerDir -Filter '*.zip' -ErrorAction SilentlyContinue |
           Select-Object -First 1

if (-not $package) {
    Write-Err2 "Kein Installationspaket in installer\ gefunden."
    Write-Host ""
    Write-Host "  Bitte das SailPoint-Paket dorthin kopieren, zum Beispiel:" -ForegroundColor Yellow
    Write-Host "      installer\SailPoint_identityiq-8.5_Software_Package.zip" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Das Paket wird bewusst NICHT eingecheckt (siehe .gitignore)," -ForegroundColor Gray
    Write-Host "  da es lizenzpflichtige Software enthaelt." -ForegroundColor Gray
    exit 1
}

$sizeMB = [math]::Round($package.Length / 1MB, 0)
Write-Ok "$($package.Name) ($sizeMB MB)"

# --- .env -----------------------------------------------------------------
Write-Step "Konfiguration"

$envFile     = Join-Path $ProjectRoot '.env'
$envExample  = Join-Path $ProjectRoot '.env.example'

if (Test-Path $envFile) {
    Write-Ok ".env ist bereits vorhanden (bleibt unveraendert)"
} else {
    Copy-Item $envExample $envFile
    Write-Ok ".env aus .env.example erzeugt"
    Write-Warn2 "Die Standardpasswoerter sind nur fuer lokale Entwicklung gedacht."
}

# --- Ports pruefen --------------------------------------------------------
Write-Step "Ports pruefen"

$ports = @{
    'IdentityIQ' = 8080
    'PostgreSQL' = 5432
    'Mailpit'    = 8025
    'DBGate'     = 5050
    'OpenLDAP'   = 1389
}

$conflict = $false
foreach ($entry in $ports.GetEnumerator()) {
    $inUse = Get-NetTCPConnection -LocalPort $entry.Value -State Listen -ErrorAction SilentlyContinue
    if ($inUse) {
        Write-Warn2 "Port $($entry.Value) ($($entry.Key)) ist bereits belegt - ggf. in .env aendern"
        $conflict = $true
    }
}
if (-not $conflict) { Write-Ok "Alle benoetigten Ports sind frei" }

# --- Build ----------------------------------------------------------------
if ($Build -or $Start) {
    Write-Step "Images bauen"
    Write-Host "  Der erste Build dauert einige Minuten:" -ForegroundColor Gray
    Write-Host "  das WAR entpackt sich auf rund 1 GB in ueber 8.900 Dateien." -ForegroundColor Gray
    Push-Location $ProjectRoot
    try {
        docker compose build
        if ($LASTEXITCODE -ne 0) { throw "Build fehlgeschlagen" }
        Write-Ok "Images gebaut"
    } finally {
        Pop-Location
    }
}

if ($Start) {
    Write-Step "Umgebung starten"
    Push-Location $ProjectRoot
    try {
        docker compose up -d
        if ($LASTEXITCODE -ne 0) { throw "Start fehlgeschlagen" }
    } finally {
        Pop-Location
    }
    Write-Ok "Container gestartet"
}

# --- Abschluss ------------------------------------------------------------
Write-Step "Fertig"

if (-not $Start) {
    Write-Host ""
    Write-Host "  Naechster Schritt:" -ForegroundColor White
    Write-Host "      docker compose up -d" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "  Nach dem Start erreichbar:" -ForegroundColor White
Write-Host "      IdentityIQ   http://localhost:8080/identityiq   (spadmin / admin)"
Write-Host "      Mailpit      http://localhost:8025"
Write-Host "      DBGate       http://localhost:5050"
Write-Host ""
Write-Host "  Der erste Start dauert mehrere Minuten - die Datenbank wird" -ForegroundColor Gray
Write-Host "  angelegt und die Basiskonfiguration importiert." -ForegroundColor Gray
Write-Host "  Fortschritt verfolgen mit:" -ForegroundColor Gray
Write-Host "      docker compose logs -f iiq-init" -ForegroundColor Cyan
Write-Host ""
