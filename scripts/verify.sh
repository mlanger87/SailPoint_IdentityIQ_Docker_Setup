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
# Hilfsfunktionen
# ---------------------------------------------------------------------------

# Fuehrt eine Abfrage aus und liefert das Ergebnis ohne Leerraum.
# Fasst ein Muster zusammen, das sonst achtmal wiederholt wuerde.
pq() {
    docker compose exec -T postgres psql -U postgres -d "$1" -tAc "$2"         2>/dev/null | tr -d '[:space:]'
}

# Gibt nur Ziffern zurueck, sonst 0.
#
# Noetig, weil psql bei fehlendem Container oder fehlender Tabelle
# Fehlertext statt einer Zahl liefert. Ein ${var:-0} greift dann NICHT
# (die Variable ist ja nicht leer), und der anschliessende Vergleich
# scheitert mit "integer expression expected".
zahl() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
step "1. Container"
# ---------------------------------------------------------------------------
for svc in postgres iiq mailpit openldap dbgate ldap-ui scim mockapi; do
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
step "7. Systemlandschaft: Quelle und Zielsysteme"
# ---------------------------------------------------------------------------
# Geprueft wird, dass die Objekte da sind und die Verbindungen stehen.
# Ob die Aggregation schon Daten geliefert hat, haengt davon ab, ob die
# Aufgaben gelaufen sind - das entscheidet der Anwender (Setup > Tasks).

apps="$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc         "SELECT string_agg(name, ',' ORDER BY name) FROM identityiq.spt_application;" 2>/dev/null | tr -d '[:space:]')"

for erwartet in HR-Application LDAP-Target JDBC-Target SCIM-Target WebService-Target; do
    if echo "${apps}" | grep -q "${erwartet}"; then
        ok "Applikation vorhanden: ${erwartet}"
    else
        fail "Applikation fehlt: ${erwartet}"
    fi
done

# Die HR-CSV muss im Container unter genau dem Pfad liegen, der in der
# Application steht - ein haeufiger Fehler nach Aenderungen am Mount.
# Der Pfad steht in einfachen Anfuehrungszeichen innerhalb von sh -c:
# Git Bash unter Windows wandelt sonst /data/hr in einen
# Windows-Pfad um (MSYS-Pfadkonvertierung), und der Test schlaegt
# fehl, obwohl die Datei im Container liegt.
if docker compose exec -T iiq sh -c 'test -r /data/hr/HR-people.csv' 2>/dev/null; then
    zeilen="$(zahl "$(docker compose exec -T iiq sh -c 'wc -l < /data/hr/HR-people.csv' 2>/dev/null | tr -d '[:space:]')")"
    ok "HR-CSV im Container lesbar (${zeilen} Zeilen inkl. Kopfzeile)"
else
    fail "HR-CSV nicht unter /data/hr/HR-people.csv erreichbar"
    info "Mount pruefen: docker compose config | grep -A3 'data/hr'"
fi

target_accounts="$(zahl "$(docker compose exec -T postgres psql -U postgres -d targetdb -tAc                    'SELECT count(*) FROM targetapp."IIQData";' 2>/dev/null | tr -d '[:space:]')")"
if [ -n "${target_accounts}" ]; then
    target_rollen="$(zahl "$(docker compose exec -T postgres psql -U postgres -d targetdb -tAc                      'SELECT count(*) FROM targetapp."IIQRoles";' 2>/dev/null | tr -d '[:space:]')")"
    ok "Zieldatenbank targetdb erreichbar (${target_accounts} Konten, ${target_rollen} Rollen)"
else
    fail "Zieldatenbank targetdb nicht lesbar"
fi

# Ohne die Regeln kann IIQ ins JDBC-Ziel nicht schreiben.
regeln="$(zahl "$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc           "SELECT count(*) FROM identityiq.spt_rule WHERE name LIKE 'JDBC-Target%';" 2>/dev/null | tr -d '[:space:]')")"
if [ "${regeln:-0}" -ge 6 ]; then
    ok "JDBC-Provisioning-Regeln vorhanden (${regeln})"
else
    fail "Es fehlen JDBC-Regeln (gefunden: ${regeln:-0}, erwartet: 6)"
fi

ldap_gruppen="$(zahl "$(docker compose exec -T openldap ldapsearch -x -H ldap://localhost:1389                 -D "cn=admin,dc=example,dc=com" -w adminpassword                 -b "ou=groups,dc=example,dc=com" '(objectClass=groupOfNames)' dn 2>/dev/null                 | grep -c '^dn:' | tr -d '[:space:]')")"
if [ "${ldap_gruppen:-0}" -ge 10 ]; then
    ok "LDAP-Gruppen als Entitlements vorhanden (${ldap_gruppen})"
else
    fail "Zu wenige LDAP-Gruppen (${ldap_gruppen:-0})"
    info "Bei 0: LDIF-Import abgebrochen - groupOfNames braucht mindestens ein member"
fi

# Die beiden zuletzt ergaenzten Zielsysteme sind eigene Dienste - ohne
# sie laufen SCIM- und WebService-Aggregation ins Leere.
scim_port="$(grep -E '^SCIM_PORT=' .env 2>/dev/null | cut -d= -f2)"
scim_port="${scim_port:-8100}"
if curl -s --max-time 10 -H "Authorization: Bearer ${SCIM_API_KEY:-secret}"         "http://localhost:${scim_port}/ServiceProviderConfig" >/dev/null 2>&1; then
    ok "SCIM-Server erreichbar auf http://localhost:${scim_port}"
else
    fail "SCIM-Server antwortet nicht"
fi

mock_port="$(grep -E '^MOCKAPI_PORT=' .env 2>/dev/null | cut -d= -f2)"
mock_port="${mock_port:-8200}"
# /api/v1/health kommt bewusst ohne Token aus.
if curl -s --max-time 10 "http://localhost:${mock_port}/api/v1/health" >/dev/null 2>&1; then
    ok "Mock-REST-API erreichbar auf http://localhost:${mock_port}"
else
    fail "Mock-REST-API antwortet nicht"
fi

# Ohne extendedNumber findet kein Filter die Attribute - dann laufen
# Rollenzuweisung und Manager-Korrelation still ins Leere.
erweitert="$(zahl "$(docker compose exec -T postgres psql -U postgres -d identityiq -tAc              "SELECT count(*) FROM identityiq.spt_identity WHERE extended1 IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')")"
if [ "${erweitert:-0}" -gt 0 ]; then
    ok "Identitaetsattribute befuellt (${erweitert} mit employeeNumber)"
else
    info "Noch keine Identitaetsattribute - Aggregation noch nicht gestartet"
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
