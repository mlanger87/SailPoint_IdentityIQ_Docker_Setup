<#
.SYNOPSIS
    Day-to-day helper for the IdentityIQ environment.

.EXAMPLE
    .\scripts\iiq.ps1 console       # open the IdentityIQ console
    .\scripts\iiq.ps1 import        # re-import data\objects
    .\scripts\iiq.ps1 logs          # follow IdentityIQ logs
    .\scripts\iiq.ps1 status        # state of all containers
    .\scripts\iiq.ps1 sql           # SQL shell on the IIQ repository (psql or sqlcmd)
    .\scripts\iiq.ps1 psql          # psql on PostgreSQL (repository or targetdb)
    .\scripts\iiq.ps1 reset         # reset EVERYTHING (with confirmation)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('console', 'import', 'logs', 'status', 'sql', 'psql', 'reset', 'restart', 'shell')]
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
            # Both nodes; the prefix tells them apart.
            docker compose logs -f iiq iiq-batch
        }

        'status' {
            docker compose ps
            Write-Host ""
            Write-Host "Available at:" -ForegroundColor White
            Write-Endpoints
        }

        'sql' {
            if ((Get-DbType) -eq 'sqlserver') {
                # sqlcmd as sa, with headers (sqlq strips them for scripts).
                # The password stays inside the container. GO runs a batch.
                docker compose exec mssql sh -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -d identityiq'
            } else {
                docker compose exec postgres psql -U identityiq -d identityiq
            }
        }

        'psql' {
            # With SQL Server as repository the IIQ databases do not exist in
            # PostgreSQL; connect to the JDBC target instead.
            if ((Get-DbType) -eq 'sqlserver') {
                docker compose exec postgres psql -U postgres -d targetdb
            } else {
                docker compose exec postgres psql -U identityiq -d identityiq
            }
        }

        'shell' {
            docker compose exec iiq bash
        }

        'restart' {
            Invoke-Compose restart iiq iiq-batch
            Write-Host "IdentityIQ nodes restarted." -ForegroundColor Green
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
