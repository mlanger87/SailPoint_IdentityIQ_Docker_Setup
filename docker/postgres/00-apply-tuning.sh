#!/bin/bash
# ===========================================================================
# Haengt das IIQ-Tuning an die vom Entrypoint erzeugte postgresql.conf an.
#
# Laeuft als erstes Skript in /docker-entrypoint-initdb.d (Praefix 00),
# also VOR der Schema-DDL und waehrend der temporaere Server laeuft.
#
# Hintergrund: "include_dir" kann nicht per "postgres -c" uebergeben
# werden - es ist ausschliesslich innerhalb einer Konfigurationsdatei
# gueltig. Anhaengen ist der robusteste Weg, der ohne Ersetzen der vom
# Image erzeugten Konfiguration auskommt.
# ===========================================================================
set -euo pipefail

TUNING_SRC="/opt/iiq/postgresql.tuning.conf"
PG_CONF="${PGDATA}/postgresql.conf"

if [ ! -f "${TUNING_SRC}" ]; then
    echo "[iiq-tuning] Keine Tuning-Datei gefunden - uebersprungen."
    exit 0
fi

# Idempotent: bei einem erneuten Lauf nicht doppelt anhaengen.
if grep -q "IIQ-TUNING-BEGIN" "${PG_CONF}"; then
    echo "[iiq-tuning] Tuning ist bereits aktiv."
    exit 0
fi

echo "[iiq-tuning] Haenge IdentityIQ-Tuning an ${PG_CONF} an."
{
    echo ""
    echo "# --- IIQ-TUNING-BEGIN (automatisch angehaengt) ---"
    cat "${TUNING_SRC}"
    echo "# --- IIQ-TUNING-END ---"
} >> "${PG_CONF}"

# Die Einstellungen sollen schon fuer die nachfolgende Schema-DDL gelten.
# Ein Reload genuegt fuer alle Parameter ausser max_connections und
# shared_buffers - die greifen erst beim endgueltigen Serverstart, der
# ohnehin direkt nach der Initialisierung erfolgt.
pg_ctl reload -D "${PGDATA}" >/dev/null 2>&1 || true

echo "[iiq-tuning] Fertig."
