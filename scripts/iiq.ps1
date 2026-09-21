<#
.SYNOPSIS
    Sammelskript fuer den Alltag mit der IdentityIQ-Umgebung.

.EXAMPLE
    .\scripts\iiq.ps1 console       # IdentityIQ-Konsole oeffnen
    .\scripts\iiq.ps1 import        # data\objects erneut importieren
    .\scripts\iiq.ps1 logs          # Logs von IdentityIQ folgen
    .\scripts\iiq.ps1 status        # Zustand aller Container
    .\scripts\iiq.ps1 psql          # psql auf der IIQ-Datenbank
    .\scripts\iiq.ps1 reset         # ALLES zuruecksetzen (mit Rueckfrage)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('console', 'import', 'logs', 'status', 'psql', 'reset', 'restart', 'shell')]
    [string]$Command = 'status'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $ProjectRoot

try {
    switch ($Command) {

        'console' {
            Write-Host "IdentityIQ-Konsole - 'quit' zum Beenden" -ForegroundColor Cyan
            docker compose exec iiq iiq console
        }

        'import' {
            Write-Host "Importiere data\objects neu ..." -ForegroundColor Cyan
            # Der Init-Container erkennt am Datenbankzustand, dass die
            # Basiskonfiguration schon da ist, und spielt nur die
            # eigenen Objekte erneut ein.
            docker compose up iiq-init
            Write-Host "Fertig." -ForegroundColor Green
        }

        'logs' {
            docker compose logs -f iiq
        }

        'status' {
            docker compose ps
            Write-Host ""
            Write-Host "Erreichbar unter:" -ForegroundColor White
            Write-Host "  IdentityIQ   http://localhost:8080/identityiq   (spadmin / admin)"
            Write-Host "  Mailpit      http://localhost:8025"
            Write-Host "  DBGate       http://localhost:5050"
            Write-Host "  LDAP-UI      http://localhost:5080"
        }

        'psql' {
            docker compose exec postgres psql -U identityiq -d identityiq
        }

        'shell' {
            docker compose exec iiq bash
        }

        'restart' {
            docker compose restart iiq
            Write-Host "IdentityIQ neu gestartet." -ForegroundColor Green
        }

        'reset' {
            Write-Host ""
            Write-Host "  ACHTUNG" -ForegroundColor Red
            Write-Host "  Dies loescht die Datenbank und alle in IdentityIQ" -ForegroundColor Yellow
            Write-Host "  angelegten Objekte unwiderruflich." -ForegroundColor Yellow
            Write-Host ""
            $answer = Read-Host "  Zum Bestaetigen 'ja' eingeben"
            if ($answer -ne 'ja') {
                Write-Host "  Abgebrochen." -ForegroundColor Gray
                return
            }
            docker compose down -v
            Write-Host "Zuruecksetzen abgeschlossen. Neu starten mit: docker compose up -d" -ForegroundColor Green
        }
    }
} finally {
    Pop-Location
}
