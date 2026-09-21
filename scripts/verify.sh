#!/usr/bin/env bash
# ===========================================================================
# Functional check of the running environment.
#
# Usage:  ./scripts/verify.sh
#
# Checks in order:
#   1. All containers are running and healthy
#   2. The three IIQ databases exist and are populated
#   3. The base configuration was imported
#   4. The web UI responds
#   5. The Quartz scheduler runs (PostgreSQL delegate in effect)
#   6. Mailpit is reachable
#   7. System landscape: source and target systems
# ===========================================================================
# No -e on purpose: every check must run, failures are collected in FAILED.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

# Ports and credentials from .env with compose defaults.
# shellcheck source=scripts/env.sh
source "${PROJECT_ROOT}/scripts/env.sh"

FAILED=0

step()  { printf '\n=== %s ===\n' "$1"; }
ok()    { printf '  [ok]   %s\n' "$1"; }
fail()  { printf '  [FAIL] %s\n' "$1"; FAILED=1; }
info()  { printf '         %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Runs a query and returns the result stripped of whitespace.
# Folds a pattern that would otherwise be repeated eight times.
pq() {
    docker compose exec -T postgres psql -U postgres -d "$1" -tAc "$2" \
        2>/dev/null | tr -d '[:space:]'
}

# Returns digits only, otherwise 0.
#
# Needed because psql emits error text instead of a number when the
# container or table is missing. ${var:-0} does NOT catch that (the
# variable is not empty), and the subsequent comparison fails with
# "integer expression expected".
as_number() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
step "1. Containers"
# ---------------------------------------------------------------------------
for svc in postgres iiq mailpit openldap dbgate ldap-ui scim mockapi; do
    cid="$(docker compose ps -q "${svc}" 2>/dev/null)"
    if [ -z "${cid}" ]; then
        fail "${svc}: not running"
        continue
    fi
    state="$(docker inspect --format '{{.State.Status}}' "${cid}")"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "${cid}")"
    if [ "${state}" = "running" ] && { [ "${health}" = "healthy" ] || [ "${health}" = "-" ]; }; then
        ok "${svc}: ${state}${health:+ (${health})}"
    else
        fail "${svc}: ${state} (${health})"
    fi
done

# The init container MUST have exited with 0.
init_cid="$(docker compose ps -aq iiq-init 2>/dev/null)"
if [ -n "${init_cid}" ]; then
    code="$(docker inspect --format '{{.State.ExitCode}}' "${init_cid}")"
    if [ "${code}" = "0" ]; then
        ok "iiq-init: exited cleanly (code 0)"
    else
        fail "iiq-init: exit code ${code} - initialisation failed"
    fi
fi

# ---------------------------------------------------------------------------
step "2. Database"
# ---------------------------------------------------------------------------
for db in identityiq identityiqah identityiqPlugin; do
    if docker compose exec -T postgres psql -U postgres -tAc \
           "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null | grep -q 1; then
        ok "database ${db} present"
    else
        fail "database ${db} missing"
    fi
done

tables="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='identityiq';" 2>/dev/null | tr -d '[:space:]')"
if [ "${tables:-0}" -gt 200 ]; then
    ok "identityiq: ${tables} tables"
else
    fail "identityiq: only ${tables:-0} tables (expected: over 200)"
fi

# ---------------------------------------------------------------------------
step "3. Base configuration"
# ---------------------------------------------------------------------------
identities="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM identityiq.spt_identity;" 2>/dev/null | tr -d '[:space:]')"
if [ "${identities:-0}" -ge 1 ]; then
    ok "spt_identity: ${identities} rows (spadmin present)"
else
    fail "spt_identity is empty - init.xml was not imported"
fi

objects="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM identityiq.spt_configuration;" 2>/dev/null | tr -d '[:space:]')"
if [ "${objects:-0}" -ge 1 ]; then
    ok "spt_configuration: ${objects} rows"
else
    fail "spt_configuration is empty"
fi

# Was the custom mail configuration applied?
mailhost="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM identityiq.spt_configuration WHERE name='SystemConfiguration';" 2>/dev/null | tr -d '[:space:]')"
if [ "${mailhost:-0}" -ge 1 ]; then
    ok "SystemConfiguration present"
else
    info "SystemConfiguration not found"
fi

# ---------------------------------------------------------------------------
step "4. Web UI"
# ---------------------------------------------------------------------------
port="${IIQ_HTTP_PORT}"
# curl prints the -w code even when it exits non-zero (e.g. --max-time hit while
# the body was still streaming on a busy JVM); appending a fallback to that
# once produced "HTTP 200000". Fall back only when nothing was printed.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        "http://localhost:${port}/identityiq/login.jsf" 2>/dev/null)" || true
code="${code:-000}"
if [ "${code}" = "200" ] || [ "${code}" = "302" ]; then
    ok "login page responds (HTTP ${code})"
    info "http://localhost:${port}/identityiq  -  spadmin / admin"
else
    fail "login page does not respond (HTTP ${code})"
    info "Tomcat needs 1-3 minutes after start. Logs: docker compose logs -f iiq"
fi

# ---------------------------------------------------------------------------
step "5. Quartz scheduler (PostgreSQL delegate)"
# ---------------------------------------------------------------------------
# With a wrong delegate these tables would stay empty, or the scheduler
# would abort at startup with an exception.
triggers="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM identityiq.qrtz221_triggers;" 2>/dev/null | tr -d '[:space:]')"
if [ -n "${triggers}" ] && [ "${triggers}" -ge 0 ] 2>/dev/null; then
    ok "Quartz tables readable (${triggers} triggers)"
else
    fail "Quartz tables not readable"
fi

if docker compose logs iiq 2>/dev/null | grep -qiE "quartz.*(exception|error)"; then
    fail "Quartz errors in the log - check the delegate"
    info "docker compose logs iiq | grep -i quartz"
else
    ok "no Quartz errors in the log"
fi

# ---------------------------------------------------------------------------
step "6. Mailpit"
# ---------------------------------------------------------------------------
mp_port="${MAILPIT_UI_PORT}"
if curl -s --max-time 10 "http://localhost:${mp_port}/api/v1/info" >/dev/null 2>&1; then
    ok "Mailpit reachable at http://localhost:${mp_port}"
else
    fail "Mailpit does not respond"
fi

# ---------------------------------------------------------------------------
step "7. System landscape: source and target systems"
# ---------------------------------------------------------------------------
# Verifies that the objects exist and the connections are up. Whether
# aggregation has already delivered data depends on whether the tasks
# have run - that is up to the user (Setup > Tasks).

apps="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
        "SELECT string_agg(name, ',' ORDER BY name) FROM identityiq.spt_application;" 2>/dev/null | tr -d '[:space:]')"

for expected in HR-Application LDAP-Target JDBC-Target SCIM-Target WebService-Target; do
    if echo "${apps}" | grep -q "${expected}"; then
        ok "application present: ${expected}"
    else
        fail "application missing: ${expected}"
    fi
done

# The HR CSV must be at exactly the path configured in the Application -
# a common error after mount changes.
# The path is single-quoted inside sh -c: Git Bash on Windows would
# otherwise rewrite /data/hr into a Windows path (MSYS path conversion),
# and the test fails although the file is in the container.
if docker compose exec -T iiq sh -c 'test -r /data/hr/HR-people.csv' 2>/dev/null; then
    lines="$(as_number "$(docker compose exec -T iiq sh -c 'wc -l < /data/hr/HR-people.csv' 2>/dev/null | tr -d '[:space:]')")"
    ok "HR CSV readable in the container (${lines} lines incl. header)"
else
    fail "HR CSV not reachable at /data/hr/HR-people.csv"
    info "check the mount: docker compose config | grep -A3 'data/hr'"
fi

target_accounts="$(as_number "$(docker compose exec -T postgres psql -U postgres -d targetdb -tAc \
                   'SELECT count(*) FROM targetapp."IIQData";' 2>/dev/null | tr -d '[:space:]')")"
if [ -n "${target_accounts}" ]; then
    target_roles="$(as_number "$(docker compose exec -T postgres psql -U postgres -d targetdb -tAc \
                    'SELECT count(*) FROM targetapp."IIQRoles";' 2>/dev/null | tr -d '[:space:]')")"
    ok "target database targetdb reachable (${target_accounts} accounts, ${target_roles} roles)"
else
    fail "target database targetdb not readable"
fi

# Without the rules IIQ cannot write to the JDBC target.
rules="$(as_number "$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
         "SELECT count(*) FROM identityiq.spt_rule WHERE name LIKE 'JDBC-Target%';" 2>/dev/null | tr -d '[:space:]')")"
if [ "${rules:-0}" -ge 6 ]; then
    ok "JDBC provisioning rules present (${rules})"
else
    fail "JDBC rules missing (found: ${rules:-0}, expected: 6)"
fi

ldap_groups="$(as_number "$(docker compose exec -T openldap ldapsearch -x -H ldap://localhost:1389 \
               -D "cn=${LDAP_ADMIN_USER},${LDAP_ROOT}" -w "${LDAP_ADMIN_PASSWORD}" \
               -b "ou=groups,${LDAP_ROOT}" '(objectClass=groupOfNames)' dn 2>/dev/null \
               | grep -c '^dn:' | tr -d '[:space:]')")"
if [ "${ldap_groups:-0}" -ge 10 ]; then
    ok "LDAP groups present as entitlements (${ldap_groups})"
else
    fail "too few LDAP groups (${ldap_groups:-0})"
    info "if 0: LDIF import aborted - groupOfNames needs at least one member"
fi

# The two most recently added targets are separate services - without
# them SCIM and WebService aggregation run into nothing.
scim_port="${SCIM_PORT}"
if curl -s --max-time 10 -H "Authorization: Bearer ${SCIM_API_KEY}" \
        "http://localhost:${scim_port}/ServiceProviderConfig" >/dev/null 2>&1; then
    ok "SCIM server reachable at http://localhost:${scim_port}"
else
    fail "SCIM server does not respond"
fi

mock_port="${MOCKAPI_PORT}"
# /api/v1/health deliberately needs no token.
if curl -s --max-time 10 "http://localhost:${mock_port}/api/v1/health" >/dev/null 2>&1; then
    ok "mock REST API reachable at http://localhost:${mock_port}"
else
    fail "mock REST API does not respond"
fi

# Without extendedNumber no filter finds the attributes - role assignment
# and manager correlation then silently run into nothing.
extended="$(as_number "$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
            "SELECT count(*) FROM identityiq.spt_identity WHERE extended1 IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')")"
if [ "${extended:-0}" -gt 0 ]; then
    ok "identity attributes populated (${extended} with employeeNumber)"
else
    info "no identity attributes yet - aggregation not started"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "${FAILED}" -eq 0 ]; then
    printf '=== All checks passed ===\n\n'
    exit 0
else
    printf '=== There were failures (see above) ===\n\n'
    exit 1
fi
