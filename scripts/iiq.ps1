<#
.SYNOPSIS
    Day-to-day helper for the IdentityIQ environment.

.EXAMPLE
    .\scripts\iiq.ps1 console       # open the IdentityIQ console
    .\scripts\iiq.ps1 import        # re-import data\objects
    .\scripts\iiq.ps1 logs          # follow IdentityIQ logs
    .\scripts\iiq.ps1 status        # state of all containers
    .\scripts\iiq.ps1 psql          # psql on the IIQ database
    .\scripts\iiq.ps1 reset         # reset EVERYTHING (with confirmation)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('console', 'import', 'logs', 'status', 'psql', 'reset', 'restart', 'shell')]
    [string]$Command = 'status'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\env.ps1"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $ProjectRoot

try {
    switch ($Command) {

        'console' {
            Write-Host "IdentityIQ console - 'quit' to exit" -ForegroundColor Cyan
            docker compose exec iiq iiq console
        }

        'import' {
            Write-Host "Re-importing data\objects ..." -ForegroundColor Cyan
            # The init container detects from the database state that the
            # base configuration is already present and only re-imports
            # the custom objects. Note: import never deletes - an object
            # removed or renamed in the files stays in the database.
            Invoke-Compose up iiq-init
            Write-Host "Done." -ForegroundColor Green
        }

        'logs' {
            docker compose logs -f iiq
        }

        'status' {
            docker compose ps
            Write-Host ""
            Write-Host "Available at:" -ForegroundColor White
            Write-Endpoints
        }

        'psql' {
            docker compose exec postgres psql -U identityiq -d identityiq
        }

        'shell' {
            docker compose exec iiq bash
        }

        'restart' {
            Invoke-Compose restart iiq
            Write-Host "IdentityIQ restarted." -ForegroundColor Green
        }

        'reset' {
            Write-Host ""
            Write-Host "  WARNING" -ForegroundColor Red
            Write-Host "  This irreversibly deletes the database and all objects" -ForegroundColor Yellow
            Write-Host "  created in IdentityIQ." -ForegroundColor Yellow
            Write-Host ""
            $answer = Read-Host "  Type 'yes' to confirm"
            if ($answer -ne 'yes') {
                Write-Host "  Aborted." -ForegroundColor Gray
                return
            }
            Invoke-Compose down -v
            Write-Host "Reset complete. Start again with: docker compose up -d" -ForegroundColor Green
        }
    }
} finally {
    Pop-Location
}
