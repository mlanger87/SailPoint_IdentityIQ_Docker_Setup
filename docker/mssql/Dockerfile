# ===========================================================================
# SQL Server 2022 with the IdentityIQ schema pre-provisioned
# ---------------------------------------------------------------------------
# Alternative repository database, selected through the compose overlay
# docker-compose.sqlserver.yml. PostgreSQL stays in the stack either way:
# it hosts the JDBC target database (targetdb).
#
# Quirks of SailPoint's SQL Server DDL (verified against the 8.5 package):
#   - Like the PostgreSQL script it creates all three databases
#     (identityiq, identityiqah, identityiqPlugin), one login, user and
#     schema each, makes each user db_owner and turns on
#     ALLOW_SNAPSHOT_ISOLATION / READ_COMMITTED_SNAPSHOT (Guide p.19:
#     mandatory, otherwise deadlocks).
#   - It is a sqlcmd script: batches separated by GO, database switches
#     via USE. It must be run by sqlcmd.
#   - Case-insensitivity comes from the server collation; the image's
#     default SQL_Latin1_General_CP1_CI_AS is case-insensitive, the
#     compose overlay sets it explicitly anyway.
#
# The official image has no init hook directory like Postgres has; the
# entrypoint in this folder starts sqlservr, runs the DDL once and leaves
# a marker in the data volume.
# ===========================================================================

# ---------------------------------------------------------------------------
# Stage 1: pull the DDL from the installation package and parameterize it
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS ddl

# Passwords as build ARGs: same trade-off as docker/postgres/Dockerfile.
ARG IIQ_VERSION=8.5
ARG IIQ_DB_USER=identityiq
ARG IIQ_DB_PASSWORD=identityiq
ARG IIQ_PLUGIN_DB_USER=identityiqPlugin
ARG IIQ_PLUGIN_DB_PASSWORD=identityiqPlugin
ARG IIQ_AH_DB_USER=identityiqah
ARG IIQ_AH_DB_PASSWORD=identityiqah

RUN apt-get update \
 && apt-get install -y --no-install-recommends unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY installer/*.zip /work/package.zip

RUN unzip -j -o /work/package.zip \
        "database/create_identityiq_tables-${IIQ_VERSION}.sqlserver" \
        -d /work/extracted \
 && mv /work/extracted/create_identityiq_tables-${IIQ_VERSION}.sqlserver \
       /work/extracted/create-identityiq.sql

# Logins carry the passwords from .env. Only the LOGIN name changes; the
# database user and the schema keep SailPoint's names, so every
# "identityiq." prefix in the 10,000-line script stays valid.
#
# CHECK_POLICY=OFF: SQL Server on Linux enforces password complexity on
# CREATE LOGIN; the stock dev passwords ("identityiq") would be rejected
# and the whole DDL would abort at its third statement.
#
# Each substitution must hit exactly once - a silent miss would leave
# the default password in place and IIQ would fail to log in.
RUN set -eu; cd /work/extracted; f=create-identityiq.sql; \
    sub() { \
        before="$(grep -c "$1" "$f" || true)"; \
        [ "$before" = "1" ] || { echo "pattern '$1' found $before times, expected 1" >&2; exit 1; }; \
        sed -i "s|$1|$2|" "$f"; \
    }; \
    sub "^CREATE LOGIN \[identityiq\] WITH PASSWORD='identityiq'," \
        "CREATE LOGIN [${IIQ_DB_USER}] WITH PASSWORD='${IIQ_DB_PASSWORD}', CHECK_POLICY=OFF,"; \
    sub "^CREATE USER identityiq FOR LOGIN identityiq " \
        "CREATE USER identityiq FOR LOGIN [${IIQ_DB_USER}] "; \
    sub "^CREATE LOGIN \[identityiqah\] WITH PASSWORD='identityiqah'," \
        "CREATE LOGIN [${IIQ_AH_DB_USER}] WITH PASSWORD='${IIQ_AH_DB_PASSWORD}', CHECK_POLICY=OFF,"; \
    sub "^CREATE USER identityiqah FOR LOGIN identityiqah " \
        "CREATE USER identityiqah FOR LOGIN [${IIQ_AH_DB_USER}] "; \
    sub "^CREATE LOGIN \[identityiqPlugin\] WITH PASSWORD='identityiqPlugin'," \
        "CREATE LOGIN [${IIQ_PLUGIN_DB_USER}] WITH PASSWORD='${IIQ_PLUGIN_DB_PASSWORD}', CHECK_POLICY=OFF,"; \
    sub "^CREATE USER identityiqPlugin FOR LOGIN identityiqPlugin " \
        "CREATE USER identityiqPlugin FOR LOGIN [${IIQ_PLUGIN_DB_USER}] "; \
    echo "--- Check: resulting LOGIN/USER lines ---"; \
    grep -nE "^CREATE (LOGIN|USER)" "$f" | sed -E "s/PASSWORD='[^']*'/PASSWORD='***'/"

# ---------------------------------------------------------------------------
# Stage 2: runtime image
# ---------------------------------------------------------------------------
# Pinned to a cumulative update: "2022-latest" moves under you, and a CU
# can change behavior. amd64 only - Microsoft publishes no arm64 image.
FROM mcr.microsoft.com/mssql/server:2022-CU27-ubuntu-22.04

COPY --from=ddl /work/extracted/create-identityiq.sql /opt/iiq/create-identityiq.sql
COPY --chmod=755 docker/mssql/entrypoint.sh /opt/iiq/entrypoint.sh
# sqlcmd wrapper with the connection options; used by the entrypoint,
# the healthcheck and the host scripts (verify.sh, iiq.ps1 sql).
COPY --chmod=755 docker/mssql/sqlq /usr/local/bin/sqlq

# The base image already runs as mssql (uid 10001); stated explicitly so
# a future base change cannot silently turn this into root.
USER mssql

ENTRYPOINT ["/opt/iiq/entrypoint.sh"]
CMD ["/opt/mssql/bin/sqlservr"]
