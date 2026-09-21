#!/usr/bin/env bash
# ===========================================================================
# Shared environment for the bash helpers. Source it, do not execute it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
#
# Loads .env (KEY=VALUE lines) with the same defaults docker-compose.yml
# uses, and provides the endpoint table. Single source for ports and
# credentials on the host side; previously the URL list was copied into
# four scripts and drifted (SCIM and the mock API were missing).
# ===========================================================================

_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read .env without sourcing it: a value with spaces or shell characters
# must not be evaluated. Comments and blank lines are skipped.
if [ -f "${_env_root}/.env" ]; then
    while IFS= read -r _line || [ -n "${_line}" ]; do
        _line="${_line%%$'\r'}"
        case "${_line}" in
            ''|'#'*) continue ;;
        esac
        _key="${_line%%=*}"
        _val="${_line#*=}"
        case "${_key}" in
            *[!A-Za-z0-9_]*) continue ;;
        esac
        export "${_key}=${_val}"
    done < "${_env_root}/.env"
fi
unset _line _key _val

# Defaults mirror docker-compose.yml. Keep both in sync.
: "${IIQ_HTTP_PORT:=8080}"
: "${IIQ_DEBUG_PORT:=8000}"
: "${POSTGRES_PORT:=5432}"
: "${MAILPIT_UI_PORT:=8025}"
: "${DBGATE_PORT:=5050}"
: "${LDAP_PORT:=1389}"
: "${LDAP_UI_PORT:=5080}"
: "${SCIM_PORT:=8100}"
: "${MOCKAPI_PORT:=8200}"
: "${LDAP_ROOT:=dc=example,dc=com}"
: "${LDAP_ADMIN_USER:=admin}"
: "${LDAP_ADMIN_PASSWORD:=adminpassword}"
: "${SCIM_API_KEY:=secret}"
: "${MOCKAPI_TOKEN:=mocktoken}"
: "${MOCKAPI_USER:=iiq}"
: "${MOCKAPI_PASSWORD:=iiqpassword}"
export IIQ_HTTP_PORT IIQ_DEBUG_PORT POSTGRES_PORT MAILPIT_UI_PORT DBGATE_PORT \
       LDAP_PORT LDAP_UI_PORT SCIM_PORT MOCKAPI_PORT LDAP_ROOT LDAP_ADMIN_USER \
       LDAP_ADMIN_PASSWORD SCIM_API_KEY MOCKAPI_TOKEN MOCKAPI_USER MOCKAPI_PASSWORD

# Ports that must be free on the host before the stack starts.
env_published_ports() {
    printf '%s\n' "${IIQ_HTTP_PORT}" "${IIQ_DEBUG_PORT}" "${POSTGRES_PORT}" \
        "${MAILPIT_UI_PORT}" "${DBGATE_PORT}" "${LDAP_PORT}" "${LDAP_UI_PORT}" \
        "${SCIM_PORT}" "${MOCKAPI_PORT}"
}

# The endpoint table shown by setup and status. Indented by $1.
env_print_endpoints() {
    local i="${1:-  }"
    printf '%sIdentityIQ     http://localhost:%s/identityiq   (spadmin / admin)\n' "$i" "${IIQ_HTTP_PORT}"
    printf '%sMailpit        http://localhost:%s\n'              "$i" "${MAILPIT_UI_PORT}"
    printf '%sDBGate         http://localhost:%s\n'              "$i" "${DBGATE_PORT}"
    printf '%sLDAP UI        http://localhost:%s   (%s / %s)\n'   "$i" "${LDAP_UI_PORT}" "${LDAP_ADMIN_USER}" "${LDAP_ADMIN_PASSWORD}"
    printf '%sSCIM server    http://localhost:%s   (Bearer %s)\n' "$i" "${SCIM_PORT}" "${SCIM_API_KEY}"
    printf '%sMock REST API  http://localhost:%s   (Bearer %s | Basic %s/%s)\n' "$i" "${MOCKAPI_PORT}" "${MOCKAPI_TOKEN}" "${MOCKAPI_USER}" "${MOCKAPI_PASSWORD}"
    printf '%sPostgreSQL     localhost:%s   OpenLDAP localhost:%s   JDWP localhost:%s\n' "$i" "${POSTGRES_PORT}" "${LDAP_PORT}" "${IIQ_DEBUG_PORT}"
}
