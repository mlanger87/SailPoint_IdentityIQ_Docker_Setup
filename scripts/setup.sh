#!/usr/bin/env bash
# ===========================================================================
# One-time setup of the IdentityIQ Docker environment (Linux/macOS/Git Bash)
#
# Usage:
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
        *) echo "Unknown option: ${arg}" >&2; exit 1 ;;
    esac
done

step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  [ok] %s\n' "$1"; }
warn() { printf '  [!]  %s\n' "$1"; }
err()  { printf '  [xx] %s\n' "$1" >&2; }

step "Checking prerequisites"

if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    err "Docker is not reachable. Is Docker Desktop / the daemon running?"
    exit 1
fi
ok "Docker Engine $(docker version --format '{{.Server.Version}}')"

if ! docker compose version --short >/dev/null 2>&1; then
    err "'docker compose' is not available."
    exit 1
fi
ok "Docker Compose $(docker compose version --short)"

MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
MEM_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
if [ "${MEM_GB}" -lt 8 ]; then
    warn "Docker has only ${MEM_GB} GB RAM available. At least 8 GB recommended."
else
    ok "memory available to Docker: ${MEM_GB} GB"
fi

step "Checking installation package"

PACKAGE="$(find "${PROJECT_ROOT}/installer" -maxdepth 1 -name '*.zip' 2>/dev/null | head -1)"
if [ -z "${PACKAGE}" ]; then
    err "No installation package found in installer/."
    echo
    echo "  Copy the SailPoint package there, e.g.:"
    echo "      installer/SailPoint_identityiq-8.5_Software_Package.zip"
    echo
    echo "  The package is deliberately NOT checked in (see .gitignore):"
    echo "  it contains licensed software."
    exit 1
fi
ok "$(basename "${PACKAGE}") ($(( $(stat -c%s "${PACKAGE}" 2>/dev/null || stat -f%z "${PACKAGE}") / 1024 / 1024 )) MB)"

step "Configuration"

if [ -f "${PROJECT_ROOT}/.env" ]; then
    ok ".env already exists (left unchanged)"
else
    cp "${PROJECT_ROOT}/.env.example" "${PROJECT_ROOT}/.env"
    ok ".env created from .env.example"
    warn "The default passwords are for local development only."
fi

# Ports and credentials - sourced only now, after .env exists.
# shellcheck source=scripts/env.sh
source "${PROJECT_ROOT}/scripts/env.sh"

step "Checking ports"
conflict=0
for port in $(env_published_ports); do
    # bash's /dev/tcp probe: no lsof/ss/netstat dependency. A successful
    # connect means something already listens there.
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
        printf '  [warn] port %s is already in use - change it in .env if needed
' "${port}"
        conflict=1
    fi
done
[ "${conflict}" -eq 1 ] || ok "all published ports are free"

if [ "${DO_BUILD}" -eq 1 ]; then
    step "Building images"
    echo "  The first build takes several minutes:"
    echo "  the WAR unpacks to about 1 GB in over 8,900 files."
    ( cd "${PROJECT_ROOT}" && docker compose build )
    ok "images built"
fi

if [ "${DO_START}" -eq 1 ]; then
    step "Starting environment"
    ( cd "${PROJECT_ROOT}" && docker compose up -d )
    ok "containers started"
fi

step "Done"

if [ "${DO_START}" -eq 0 ]; then
    echo
    echo "  Next step:"
    echo "      docker compose up -d"
fi

echo
echo "  Available after start:"
env_print_endpoints "      "
cat <<'EOF'

  The first start takes several minutes - the database is created and
  the base configuration imported. Follow progress with:
      docker compose logs -f iiq-init

EOF
