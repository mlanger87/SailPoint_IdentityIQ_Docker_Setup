#!/usr/bin/env bash
# ===========================================================================
# Einmaliges Einrichten der IdentityIQ-Docker-Umgebung (Linux/macOS/Git-Bash)
#
# Aufruf:
#     ./scripts/setup.sh
#     ./scripts/setup.sh --build
#     ./scripts/setup.sh --start
# ===========================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DO_BUILD=0
DO_START=0

for arg in "$@"; do
    case "${arg}" in
        --build) DO_BUILD=1 ;;
        --start) DO_BUILD=1; DO_START=1 ;;
        *) echo "Unbekannte Option: ${arg}" >&2; exit 1 ;;
    esac
done

step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  [ok] %s\n' "$1"; }
warn() { printf '  [!]  %s\n' "$1"; }
err()  { printf '  [xx] %s\n' "$1" >&2; }

step "Voraussetzungen pruefen"

if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    err "Docker ist nicht erreichbar. Laeuft Docker Desktop bzw. der Daemon?"
    exit 1
fi
ok "Docker Engine $(docker version --format '{{.Server.Version}}')"

if ! docker compose version --short >/dev/null 2>&1; then
    err "'docker compose' steht nicht zur Verfuegung."
    exit 1
fi
ok "Docker Compose $(docker compose version --short)"

MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
MEM_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
if [ "${MEM_GB}" -lt 8 ]; then
    warn "Docker stehen nur ${MEM_GB} GB RAM zur Verfuegung. Empfohlen sind mindestens 8 GB."
else
    ok "Arbeitsspeicher fuer Docker: ${MEM_GB} GB"
fi

step "Installationspaket pruefen"

PACKAGE="$(find "${PROJECT_ROOT}/installer" -maxdepth 1 -name '*.zip' 2>/dev/null | head -1)"
if [ -z "${PACKAGE}" ]; then
    err "Kein Installationspaket in installer/ gefunden."
    echo
    echo "  Bitte das SailPoint-Paket dorthin kopieren, zum Beispiel:"
    echo "      installer/SailPoint_identityiq-8.5_Software_Package.zip"
    echo
    echo "  Das Paket wird bewusst NICHT eingecheckt (siehe .gitignore),"
    echo "  da es lizenzpflichtige Software enthaelt."
    exit 1
fi
ok "$(basename "${PACKAGE}") ($(( $(stat -c%s "${PACKAGE}" 2>/dev/null || stat -f%z "${PACKAGE}") / 1024 / 1024 )) MB)"

step "Konfiguration"

if [ -f "${PROJECT_ROOT}/.env" ]; then
    ok ".env ist bereits vorhanden (bleibt unveraendert)"
else
    cp "${PROJECT_ROOT}/.env.example" "${PROJECT_ROOT}/.env"
    ok ".env aus .env.example erzeugt"
    warn "Die Standardpasswoerter sind nur fuer lokale Entwicklung gedacht."
fi

if [ "${DO_BUILD}" -eq 1 ]; then
    step "Images bauen"
    echo "  Der erste Build dauert einige Minuten:"
    echo "  das WAR entpackt sich auf rund 1 GB in ueber 8.900 Dateien."
    ( cd "${PROJECT_ROOT}" && docker compose build )
    ok "Images gebaut"
fi

if [ "${DO_START}" -eq 1 ]; then
    step "Umgebung starten"
    ( cd "${PROJECT_ROOT}" && docker compose up -d )
    ok "Container gestartet"
fi

step "Fertig"

if [ "${DO_START}" -eq 0 ]; then
    echo
    echo "  Naechster Schritt:"
    echo "      docker compose up -d"
fi

cat <<'EOF'

  Nach dem Start erreichbar:
      IdentityIQ   http://localhost:8080/identityiq   (spadmin / admin)
      Mailpit      http://localhost:8025
      DBGate       http://localhost:5050

  Der erste Start dauert mehrere Minuten - die Datenbank wird angelegt
  und die Basiskonfiguration importiert. Fortschritt verfolgen mit:
      docker compose logs -f iiq-init

EOF
