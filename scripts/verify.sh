#!/usr/bin/env bash
# ===========================================================================
# Functional check of the running environment.
#
# Usage:  ./scripts/verify.sh
#
# Checks in order:
#   1. All containers are running and healthy
#   2. The three IIQ databases exist and are populated (PostgreSQL or
#      SQL Server, whichever is the repository - see env.sh)
#   3. The base configuration was imported
#   4. The web UI responds
#   5. The Quartz scheduler runs (database-specific delegate in effect)
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

# Runs a query against PostgreSQL and returns the result stripped of
# whitespace. Used directly for targetdb, which is always PostgreSQL.
pq() {
    docker compose exec -T postgres psql -U postgres -d "$1" -tAc "$2" \
        2>/dev/null | tr -d '[:space:]'
}

# Runs a query against the IdentityIQ repository, whichever database
# holds it. $1 database, $2 the statement, $3 a SQL Server variant where
# the dialects differ (string aggregation, booleans, epoch arithmetic).
# The rest is portable as written: schema-qualified names and
# information_schema mean the same on both.
iq() {
    if [ "${IIQ_DB_TYPE}" = "sqlserver" ]; then
        docker compose exec -T mssql sqlq -d "$1" -Q "SET NOCOUNT ON; ${3:-$2}" \
            2>/dev/null | tr -d '[:space:]'
    else
        pq "$1" "$2"
    fi
}

# The server-level database of each engine, for catalog queries.
if [ "${IIQ_DB_TYPE}" = "sqlserver" ]; then SERVER_DB=master; else SERVER_DB=postgres; fi

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
info "repository database: ${IIQ_DB_TYPE}"
services="postgres iiq iiq-batch mailpit openldap dbgate ldap-ui scim mockapi"
if [ "${IIQ_DB_TYPE}" = "sqlserver" ]; then services="mssql ${services}"; fi
for svc in ${services}; do
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
    if [ "$(iq "${SERVER_DB}" "SELECT 1 FROM pg_database WHERE datname='${db}';" \
                              "SELECT 1 FROM sys.databases WHERE name='${db}';")" = "1" ]; then
        ok "database ${db} present"
    else
        fail "database ${db} missing"
    fi
done

tables="$(as_number "$(iq identityiq \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='identityiq';")")"
if [ "${tables:-0}" -gt 200 ]; then
    ok "identityiq: ${tables} tables"
else
    fail "identityiq: only ${tables:-0} tables (expected: over 200)"
fi

# ---------------------------------------------------------------------------
step "3. Base configuration"
# ---------------------------------------------------------------------------
identities="$(as_number "$(iq identityiq "SELECT count(*) FROM identityiq.spt_identity;")")"
if [ "${identities:-0}" -ge 1 ]; then
    ok "spt_identity: ${identities} rows (spadmin present)"
else
    fail "spt_identity is empty - init.xml was not imported"
fi

objects="$(as_number "$(iq identityiq "SELECT count(*) FROM identityiq.spt_configuration;")")"
if [ "${objects:-0}" -ge 1 ]; then
    ok "spt_configuration: ${objects} rows"
else
    fail "spt_configuration is empty"
fi

# Was the custom mail configuration applied?
mailhost="$(as_number "$(iq identityiq \
    "SELECT count(*) FROM identityiq.spt_configuration WHERE name='SystemConfiguration';")")"
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
step "4b. Two IIQ nodes: UI and batch"
# ---------------------------------------------------------------------------
# Both nodes register a Server object named after -Diiq.hostname and refresh
# its heartbeat; the Task and Request services are pinned to the batch node
# through data/objects/05-ServiceDefinitions.xml.
bport="${IIQ_BATCH_HTTP_PORT}"
bcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15         "http://localhost:${bport}/identityiq/login.jsf" 2>/dev/null)" || true
bcode="${bcode:-000}"
if [ "${bcode}" = "200" ] || [ "${bcode}" = "302" ]; then
    ok "batch node login page responds (HTTP ${bcode})"
else
    fail "batch node login page does not respond (HTTP ${bcode})"
    info "docker compose logs -f iiq-batch"
fi

# Heartbeat within the last 2 minutes = the node is alive from IIQ's view.
live_nodes="$(iq identityiq \
    "SELECT string_agg(name, ',' ORDER BY name) FROM identityiq.spt_server
      WHERE inactive = false AND name NOT LIKE '%-console'
        AND heartbeat > (extract(epoch from now()) * 1000)::bigint - 120000;" \
    "SELECT string_agg(name, ',') WITHIN GROUP (ORDER BY name) FROM identityiq.spt_server
      WHERE inactive = 0 AND name NOT LIKE '%-console'
        AND heartbeat > DATEDIFF_BIG(millisecond, '1970-01-01', SYSUTCDATETIME()) - 120000;")"
case ",${live_nodes}," in
    *,iiq-batch,*) ok "Server objects with a fresh heartbeat: ${live_nodes}" ;;
    *) fail "batch node has no fresh heartbeat (live: ${live_nodes:-none})" ;;
esac

task_hosts="$(iq identityiq "SELECT hosts FROM identityiq.spt_service_definition WHERE name='Task';")"
if [ "${task_hosts}" = "iiq-batch" ]; then
    ok "Task service pinned to hosts=${task_hosts}"
else
    fail "Task service hosts='${task_hosts}' (expected iiq-batch; is 05-ServiceDefinitions.xml imported?)"
fi

# ---------------------------------------------------------------------------
step "5. Quartz scheduler (${IIQ_DB_TYPE} delegate)"
# ---------------------------------------------------------------------------
# With a wrong delegate these tables would stay empty, or the scheduler
# would abort at startup with an exception.
triggers="$(iq identityiq "SELECT count(*) FROM identityiq.qrtz221_triggers;")"
if [ -n "${triggers}" ] && [ "${triggers}" -ge 0 ] 2>/dev/null; then
    ok "Quartz tables readable (${triggers} triggers)"
else
    fail "Quartz tables not readable"
fi

if docker compose logs iiq iiq-batch 2>/dev/null | grep -qiE "quartz.*(exception|error)"; then
    fail "Quartz errors in the log - check the delegate"
    info "docker compose logs iiq iiq-batch | grep -i quartz"
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

apps="$(iq identityiq \
        "SELECT string_agg(name, ',' ORDER BY name) FROM identityiq.spt_application;" \
        "SELECT string_agg(name, ',') WITHIN GROUP (ORDER BY name) FROM identityiq.spt_application;")"

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

target_accounts="$(as_number "$(pq targetdb 'SELECT count(*) FROM targetapp."IIQData";')")"
if [ -n "${target_accounts}" ]; then
    target_roles="$(as_number "$(pq targetdb 'SELECT count(*) FROM targetapp."IIQRoles";')")"
    ok "target database targetdb reachable (${target_accounts} accounts, ${target_roles} roles)"
else
    fail "target database targetdb not readable"
fi

# Without the rules IIQ cannot write to the JDBC target.
rules="$(as_number "$(iq identityiq "SELECT count(*) FROM identityiq.spt_rule WHERE name LIKE 'JDBC-Target%';")")"
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
extended="$(as_number "$(iq identityiq "SELECT count(*) FROM identityiq.spt_identity WHERE extended1 IS NOT NULL;")")"
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
