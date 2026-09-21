#!/usr/bin/env bash
# ===========================================================================
# Funktionspruefung der laufenden Umgebung.
#
# Aufruf:  ./scripts/verify.sh
#
# Prueft der Reihe nach:
#   1. Alle Container laufen und sind gesund
#   2. Die drei IIQ-Datenbanken existieren und sind gefuellt
#   3. Die Basiskonfiguration wurde importiert
#   4. Die Weboberflaeche antwortet
#   5. Der Quartz-Scheduler laeuft (PostgreSQL-Delegate greift)
#   6. Mailpit ist erreichbar
# ===========================================================================
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

FAILED=0

step()  { printf '\n=== %s ===\n' "$1"; }
ok()    { printf '  [ok]   %s\n' "$1"; }
fail()  { printf '  [FAIL] %s\n' "$1"; FAILED=1; }
info()  { printf '         %s\n' "$1"; }

# ---------------------------------------------------------------------------
step "1. Container"
# ---------------------------------------------------------------------------
for svc in postgres iiq mailpit openldap dbgate ldap-ui; do
    cid="$(docker compose ps -q "${svc}" 2>/dev/null)"
    if [ -z "${cid}" ]; then
        fail "${svc}: laeuft nicht"
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

# Der Init-Container MUSS sich mit 0 beendet haben.
init_cid="$(docker compose ps -aq iiq-init 2>/dev/null)"
if [ -n "${init_cid}" ]; then
    code="$(docker inspect --format '{{.State.ExitCode}}' "${init_cid}")"
    if [ "${code}" = "0" ]; then
        ok "iiq-init: sauber beendet (Code 0)"
    else
        fail "iiq-init: Exitcode ${code} - Initialisierung fehlgeschlagen"
    fi
fi

# ---------------------------------------------------------------------------
step "2. Datenbank"
# ---------------------------------------------------------------------------
for db in identityiq identityiqah identityiqPlugin; do
    if docker compose exec -T postgres psql -U postgres -tAc \
           "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null | grep -q 1; then
        ok "Datenbank ${db} vorhanden"
    else
        fail "Datenbank ${db} fehlt"
    fi
done

tables="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='identityiq';" 2>/dev/null | tr -d '[:space:]')"
if [ "${tables:-0}" -gt 200 ]; then
    ok "identityiq: ${tables} Tabellen"
else
    fail "identityiq: nur ${tables:-0} Tabellen (erwartet: ueber 200)"
fi

# ---------------------------------------------------------------------------
step "3. Basiskonfiguration"
# ---------------------------------------------------------------------------
identities="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM identityiq.spt_identity;" 2>/dev/null | tr -d '[:space:]')"
if [ "${identities:-0}" -ge 1 ]; then
    ok "spt_identity: ${identities} Eintraege (spadmin vorhanden)"
else
    fail "spt_identity ist leer - init.xml wurde nicht importiert"
fi

objects="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM identityiq.spt_configuration;" 2>/dev/null | tr -d '[:space:]')"
if [ "${objects:-0}" -ge 1 ]; then
    ok "spt_configuration: ${objects} Eintraege"
else
    fail "spt_configuration ist leer"
fi

# Wurde die eigene Mail-Konfiguration uebernommen?
mailhost="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM identityiq.spt_configuration WHERE name='SystemConfiguration';" 2>/dev/null | tr -d '[:space:]')"
if [ "${mailhost:-0}" -ge 1 ]; then
    ok "SystemConfiguration vorhanden"
else
    info "SystemConfiguration nicht gefunden"
fi

# ---------------------------------------------------------------------------
step "4. Weboberflaeche"
# ---------------------------------------------------------------------------
port="$(grep -E '^IIQ_HTTP_PORT=' .env 2>/dev/null | cut -d= -f2)"
port="${port:-8080}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        "http://localhost:${port}/identityiq/login.jsf" 2>/dev/null || echo 000)"
if [ "${code}" = "200" ] || [ "${code}" = "302" ]; then
    ok "Login-Seite antwortet (HTTP ${code})"
    info "http://localhost:${port}/identityiq  -  spadmin / admin"
else
    fail "Login-Seite antwortet nicht (HTTP ${code})"
    info "Tomcat braucht nach dem Start 1-3 Minuten. Logs: docker compose logs -f iiq"
fi

# ---------------------------------------------------------------------------
step "5. Quartz-Scheduler (PostgreSQL-Delegate)"
# ---------------------------------------------------------------------------
# Wenn der Delegate falsch waere, blieben diese Tabellen leer bzw. der
# Scheduler wuerde beim Start mit einer Exception abbrechen.
triggers="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc \
    "SELECT count(*) FROM identityiq.qrtz221_triggers;" 2>/dev/null | tr -d '[:space:]')"
if [ -n "${triggers}" ] && [ "${triggers}" -ge 0 ] 2>/dev/null; then
    ok "Quartz-Tabellen ansprechbar (${triggers} Trigger)"
else
    fail "Quartz-Tabellen nicht lesbar"
fi

if docker compose logs iiq 2>/dev/null | grep -qiE "quartz.*(exception|error)"; then
    fail "Im Log stehen Quartz-Fehler - Delegate pruefen"
    info "docker compose logs iiq | grep -i quartz"
else
    ok "Keine Quartz-Fehler im Log"
fi

# ---------------------------------------------------------------------------
step "6. Mailpit"
# ---------------------------------------------------------------------------
mp_port="$(grep -E '^MAILPIT_UI_PORT=' .env 2>/dev/null | cut -d= -f2)"
mp_port="${mp_port:-8025}"
if curl -s --max-time 10 "http://localhost:${mp_port}/api/v1/info" >/dev/null 2>&1; then
    ok "Mailpit erreichbar auf http://localhost:${mp_port}"
else
    fail "Mailpit antwortet nicht"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "${FAILED}" -eq 0 ]; then
    printf '=== Alle Pruefungen bestanden ===\n\n'
    exit 0
else
    printf '=== Es gab Fehler (siehe oben) ===\n\n'
    exit 1
fi
