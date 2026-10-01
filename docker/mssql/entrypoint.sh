#!/bin/bash
# ===========================================================================
# Entrypoint for the SQL Server container.
#
# Starts sqlservr in the background, creates the IdentityIQ schema once,
# then waits on the server process. The official image has no
# /docker-entrypoint-initdb.d equivalent, hence this wrapper.
#
# "Once" is a marker file in the data volume, written only after the DDL
# ran without error. It lives and dies with the databases themselves (the
# same volume), which is the property the Postgres initdb hooks have too.
# The healthcheck requires the marker, so iiq-init never connects to a
# half-built schema.
# ===========================================================================
set -euo pipefail

MARKER=/var/opt/mssql/.iiq-repository-ready
DDL=/opt/iiq/create-identityiq.sql
START_TIMEOUT="${START_TIMEOUT:-120}"

log() { echo "[mssql-entrypoint] $*"; }

/opt/mssql/bin/launch_sqlservr.sh "$@" &
pid=$!

# docker stop sends TERM to PID 1 (this script); sqlservr must get it to
# shut down cleanly instead of being killed after the grace period.
trap 'kill -TERM "${pid}" 2>/dev/null || true' TERM INT

if [ ! -f "${MARKER}" ]; then
    log "Waiting for SQL Server (max ${START_TIMEOUT}s)."
    waited=0
    until sqlq -Q "SELECT 1" >/dev/null 2>&1; do
        kill -0 "${pid}" 2>/dev/null || { log "ERROR: sqlservr exited during startup."; exit 1; }
        if [ "${waited}" -ge "${START_TIMEOUT}" ]; then
            log "ERROR: SQL Server not ready after ${START_TIMEOUT}s."
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # Databases without a marker: an earlier run aborted mid-DDL. Running
    # the script again would fail on CREATE DATABASE; say what to do.
    existing="$(sqlq -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name = 'identityiq'")"
    if [ -n "${existing}" ]; then
        log "ERROR: database identityiq exists, but the schema was never completed."
        log "Reset the volume: docker compose rm -sf mssql && docker volume rm sailpoint-identityiq85_mssqldata"
        exit 1
    fi

    log "Creating the IdentityIQ databases and schema (takes a minute or two)."
    # -x: no sqlcmd variable substitution; the DDL is taken literally.
    sqlq -x -i "${DDL}" >/tmp/iiq-ddl.log 2>&1 || {
        log "ERROR: DDL failed. Last lines:"
        tail -20 /tmp/iiq-ddl.log
        exit 1
    }
    touch "${MARKER}"
    log "Schema created: $(sqlq -d identityiq -Q "SET NOCOUNT ON; SELECT count(*) FROM information_schema.tables WHERE table_schema = 'identityiq'") tables in identityiq."
fi

# A trapped signal interrupts the first wait; the second one waits for
# sqlservr to finish its shutdown.
set +e
wait "${pid}"
rc=$?
if kill -0 "${pid}" 2>/dev/null; then
    wait "${pid}"
    rc=$?
fi
exit "${rc}"
