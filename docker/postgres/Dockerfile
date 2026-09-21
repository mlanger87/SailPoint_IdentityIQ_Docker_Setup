# ===========================================================================
# PostgreSQL 17 with the IdentityIQ schema pre-provisioned
# ---------------------------------------------------------------------------
# The schema is NOT created at runtime by an SQL client in the app
# container (reference projects A and D do that) but via the official
# Postgres image's native /docker-entrypoint-initdb.d mechanism. Benefits:
# runs exactly once (when the data directory is empty), needs no marker,
# and the app container stays free of database tooling.
#
# Quirks of SailPoint's PostgreSQL DDL (verified against the 8.5 package):
#   - It creates ALL three databases itself (identityiq, identityiqah,
#     identityiqPlugin) including the three users.
#     => POSTGRES_DB must therefore NOT be set.
#   - It contains 9 psql meta-commands (\connect) to switch databases.
#     => It must be run by psql, not through a generic JDBC/SQL driver.
#   - Case-insensitive search is solved via 244 functional indexes on
#     upper(). NO special collation is needed.
# ===========================================================================

# ---------------------------------------------------------------------------
# Stage 1: pull the DDL from the installation package and parameterize it
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS ddl

# On the password ARGs (linter warning docker:S6472):
# Accepted deliberately. SailPoint's DDL creates the database users via
# "CREATE USER ... ENCRYPTED PASSWORD"; the passwords therefore have to
# be in the SQL file at build time. They end up in this intermediate
# stage's build history.
#
# Acceptable for a local dev environment - the values are in .env anyway
# and the DB is not exposed.
# For production, use BuildKit secrets (RUN --mount=type=secret) or a
# subsequent ALTER USER from a Docker secret instead.
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

# The installation package is passed into the build context from installer/.
COPY installer/*.zip /work/package.zip

# Extract only the required DDL - not the whole 770 MB package.
RUN unzip -j -o /work/package.zip \
        "database/create_identityiq_tables-${IIQ_VERSION}.postgresql" \
        -d /work/extracted \
 && mv /work/extracted/create_identityiq_tables-${IIQ_VERSION}.postgresql \
       /work/extracted/01-create-identityiq.sql

# SailPoint's DDL hard-codes the default passwords
# (CREATE USER identityiq WITH ENCRYPTED PASSWORD 'identityiq').
# They are replaced here with the values from .env.
# Pattern from reference project C (database-setup.mssql.sh).
#
# Touch only the CREATE USER lines so no identically named identifiers
# elsewhere in the 9,146-line file are hit.
RUN cd /work/extracted \
 && sed -i \
      -e "s|^CREATE USER identityiq WITH ENCRYPTED PASSWORD 'identityiq';|CREATE USER ${IIQ_DB_USER} WITH ENCRYPTED PASSWORD '${IIQ_DB_PASSWORD}';|" \
      -e "s|^CREATE USER \"identityiqPlugin\" WITH ENCRYPTED PASSWORD 'identityiqPlugin';|CREATE USER \"${IIQ_PLUGIN_DB_USER}\" WITH ENCRYPTED PASSWORD '${IIQ_PLUGIN_DB_PASSWORD}';|" \
      -e "s|^CREATE USER identityiqah WITH ENCRYPTED PASSWORD 'identityiqah';|CREATE USER ${IIQ_AH_DB_USER} WITH ENCRYPTED PASSWORD '${IIQ_AH_DB_PASSWORD}';|" \
      01-create-identityiq.sql \
 && echo "--- Check: resulting CREATE USER lines ---" \
 && grep -n "^CREATE USER" 01-create-identityiq.sql

# ---------------------------------------------------------------------------
# Stage 2: runtime image
# ---------------------------------------------------------------------------
FROM postgres:17-bookworm

# Executed automatically by psql on first start (alphabetical order).
COPY --from=ddl /work/extracted/01-create-identityiq.sql \
                /docker-entrypoint-initdb.d/01-create-identityiq.sql

# Sets search_path to the IIQ schemas so tables are found without a
# schema prefix (DBGate, psql, ad-hoc queries).
# Must run AFTER the schema DDL - hence prefix 02.
COPY docker/postgres/02-search-path.sql \
     /docker-entrypoint-initdb.d/02-search-path.sql

# Fourth database as target system for the JDBC connector. Deliberately
# in the same container: the PostgreSQL JDBC driver is already in the
# IIQ image; a second DBMS would add nothing.
COPY docker/postgres/03-targetdb.sql \
     /docker-entrypoint-initdb.d/03-targetdb.sql

# Seed rows for targetdb, generated from the same person list as the HR
# CSV (scripts/generate-testdata.py). Runs after the DDL - prefix 04.
COPY docker/postgres/04-targetdb-seed.sql \
     /docker-entrypoint-initdb.d/04-targetdb-seed.sql

# Tuning for IdentityIQ.
#
# "include_dir" can NOT be set via "postgres -c" (it is only valid inside
# a configuration file, otherwise: FATAL unrecognized configuration
# parameter). The tuning is therefore appended as an initdb hook to the
# postgresql.conf generated by the entrypoint.
#
# Scripts in /docker-entrypoint-initdb.d run alphabetically; the 00
# prefix ensures the configuration lands before the DDL.
COPY docker/postgres/postgresql.tuning.conf /opt/iiq/postgresql.tuning.conf
COPY docker/postgres/00-apply-tuning.sh     /docker-entrypoint-initdb.d/00-apply-tuning.sh
