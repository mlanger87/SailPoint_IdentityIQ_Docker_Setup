#!/bin/bash
# ===========================================================================
# Creates the IdentityIQ databases - only when PostgreSQL IS the
# repository.
#
# With the SQL Server overlay (docker-compose.sqlserver.yml) this
# container still runs, but only as the JDBC target system (targetdb).
# Three empty IIQ databases next to it would look like a second,
# abandoned repository in DBGate and psql; the overlay sets
# IIQ_DB_TYPE=sqlserver and this hook skips.
#
# Executed (not sourced) by the Postgres entrypoint, while the temporary
# init server listens on the Unix socket only. Runs once per empty
# volume, like every initdb hook: switching the repository type needs
# a fresh pgdata volume to take effect here.
# ===========================================================================
set -euo pipefail

if [ "${IIQ_DB_TYPE:-postgresql}" != "postgresql" ]; then
    echo "[iiq-repository] IIQ_DB_TYPE=${IIQ_DB_TYPE} - IdentityIQ schema not created here."
    exit 0
fi

run_sql() {
    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" \
         --no-password --no-psqlrc --dbname postgres -f "$1"
}

echo "[iiq-repository] Creating the IdentityIQ databases and schema."
# SailPoint's DDL: creates identityiq, identityiqah, identityiqPlugin
# and their roles itself (\connect inside), hence --dbname postgres.
run_sql /opt/iiq/sql/create-identityiq.sql
# search_path per role and database; must run after the DDL.
run_sql /opt/iiq/sql/search-path.sql
