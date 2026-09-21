<#
.SYNOPSIS
    Shared environment for the PowerShell helpers. Dot-source it:

        . "$PSScriptRoot\env.ps1"

    Loads .env with the same defaults docker-compose.yml uses and provides
    the endpoint table. Single source for ports and credentials on the
    host side; the URL list used to be copied into several scripts and
    drifted (SCIM and the mock API were missing).
#>

$script:EnvRoot = Split-Path -Parent $PSScriptRoot

# Defaults mirror docker-compose.yml. Keep both in sync.
$script:EnvDefaults = @{
    IIQ_HTTP_PORT       = '8080'
    IIQ_DEBUG_PORT      = '8000'
    POSTGRES_PORT       = '5432'
    MAILPIT_UI_PORT     = '8025'
    DBGATE_PORT         = '5050'
    LDAP_PORT           = '1389'
    LDAP_UI_PORT        = '5080'
    SCIM_PORT           = '8100'
    MOCKAPI_PORT        = '8200'
    LDAP_ROOT           = 'dc=example,dc=com'
    LDAP_ADMIN_USER     = 'admin'
    LDAP_ADMIN_PASSWORD = 'adminpassword'
    SCIM_API_KEY        = 'secret'
    MOCKAPI_TOKEN       = 'mocktoken'
    MOCKAPI_USER        = 'iiq'
    MOCKAPI_PASSWORD    = 'iiqpassword'
}

function Get-DotEnv {
    <# Returns a hashtable: defaults overlaid with KEY=VALUE lines from .env. #>
    $values = @{} + $script:EnvDefaults
    $envFile = Join-Path $script:EnvRoot '.env'
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            $line = $line.Trim()
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $idx = $line.IndexOf('=')
            if ($idx -lt 1) { continue }
            $key = $line.Substring(0, $idx).Trim()
            if ($key -notmatch '^[A-Za-z0-9_]+$') { continue }
            $values[$key] = $line.Substring($idx + 1)
        }
    }
    return $values
}

function Get-PublishedPorts {
    <# Host ports that must be free before the stack starts; name -> port. #>
    $e = Get-DotEnv
    return [ordered]@{
        'IdentityIQ'    = [int]$e.IIQ_HTTP_PORT
        'JDWP'          = [int]$e.IIQ_DEBUG_PORT
        'PostgreSQL'    = [int]$e.POSTGRES_PORT
        'Mailpit'       = [int]$e.MAILPIT_UI_PORT
        'DBGate'        = [int]$e.DBGATE_PORT
        'OpenLDAP'      = [int]$e.LDAP_PORT
        'LDAP UI'       = [int]$e.LDAP_UI_PORT
        'SCIM'          = [int]$e.SCIM_PORT
        'Mock REST API' = [int]$e.MOCKAPI_PORT
    }
}

function Write-Endpoints {
    <# The endpoint table shown by setup and status. #>
    param([string]$Indent = '  ')
    $e = Get-DotEnv
    Write-Host "${Indent}IdentityIQ     http://localhost:$($e.IIQ_HTTP_PORT)/identityiq   (spadmin / admin)"
    Write-Host "${Indent}Mailpit        http://localhost:$($e.MAILPIT_UI_PORT)"
    Write-Host "${Indent}DBGate         http://localhost:$($e.DBGATE_PORT)"
    Write-Host "${Indent}LDAP UI        http://localhost:$($e.LDAP_UI_PORT)   ($($e.LDAP_ADMIN_USER) / $($e.LDAP_ADMIN_PASSWORD))"
    Write-Host "${Indent}SCIM server    http://localhost:$($e.SCIM_PORT)   (Bearer $($e.SCIM_API_KEY))"
    Write-Host "${Indent}Mock REST API  http://localhost:$($e.MOCKAPI_PORT)   (Bearer $($e.MOCKAPI_TOKEN) | Basic $($e.MOCKAPI_USER)/$($e.MOCKAPI_PASSWORD))"
    Write-Host "${Indent}PostgreSQL     localhost:$($e.POSTGRES_PORT)   OpenLDAP localhost:$($e.LDAP_PORT)   JDWP localhost:$($e.IIQ_DEBUG_PORT)"
}

function Invoke-Compose {
    <#
        Runs `docker compose <args>` and throws on a non-zero exit code.
        $ErrorActionPreference = 'Stop' does not cover native executables
        in PowerShell 5.1, so a failed `docker compose up` would otherwise
        be followed by a green "Done.".
    #>
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ComposeArgs)
    & docker compose @ComposeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose $($ComposeArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}
