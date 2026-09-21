#!/bin/bash
# ===========================================================================
# Switches iiq.properties to PostgreSQL.
#
# Runs at BUILD time on the unpacked webapp.
#
# Why targeted patching instead of a full replacement file:
# The shipped iiq.properties has 400+ lines and, besides the DataSources,
# holds many other settings (rule pools, Hibernate listeners, task
# threads ...). A full custom copy would have to be re-synced on every
# IIQ upgrade. So only the database-specific keys are replaced.
#
# Reference project A does a global "sed s/localhost/host/g" here - that
# also hits non-DataSource keys. Here every key is replaced individually
# and anchored (^).
# ===========================================================================
set -euo pipefail

PROPS="${1:?path to iiq.properties missing}"

DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
IIQ_DB_USER="${IIQ_DB_USER:-identityiq}"
IIQ_DB_PASSWORD="${IIQ_DB_PASSWORD:-identityiq}"
IIQ_PLUGIN_DB_USER="${IIQ_PLUGIN_DB_USER:-identityiqPlugin}"
IIQ_PLUGIN_DB_PASSWORD="${IIQ_PLUGIN_DB_PASSWORD:-identityiqPlugin}"
IIQ_AH_DB_USER="${IIQ_AH_DB_USER:-identityiqah}"
IIQ_AH_DB_PASSWORD="${IIQ_AH_DB_PASSWORD:-identityiqah}"

echo "[iiq.properties] Switching to PostgreSQL (${DB_HOST}:${DB_PORT})"

if [ ! -f "${PROPS}" ]; then
    echo "[iiq.properties] ERROR: ${PROPS} not found." >&2
    exit 1
fi

cp "${PROPS}" "${PROPS}.orig"

# ---------------------------------------------------------------------------
# Comment out every database-related line pointing at MySQL, then append
# a clean PostgreSQL block. Appended values win, since iiq.properties
# prefers later-read keys.
# Pattern from reference project C (configureMssqlProperties).
# ---------------------------------------------------------------------------
sed -i -E \
    -e 's|^(dataSource\.url=.*)$|#\1|' \
    -e 's|^(dataSource\.driverClassName=.*)$|#\1|' \
    -e 's|^(dataSource\.username=.*)$|#\1|' \
    -e 's|^(dataSource\.password=.*)$|#\1|' \
    -e 's|^(sessionFactory\.hibernateProperties\.hibernate\.dialect=.*)$|#\1|' \
    -e 's|^(pluginsDataSource\.url=.*)$|#\1|' \
    -e 's|^(pluginsDataSource\.driverClassName=.*)$|#\1|' \
    -e 's|^(pluginsDataSource\.username=.*)$|#\1|' \
    -e 's|^(pluginsDataSource\.password=.*)$|#\1|' \
    -e 's|^(dataSourceAccessHistory\.url=.*)$|#\1|' \
    -e 's|^(dataSourceAccessHistory\.driverClassName=.*)$|#\1|' \
    -e 's|^(dataSourceAccessHistory\.username=.*)$|#\1|' \
    -e 's|^(dataSourceAccessHistory\.password=.*)$|#\1|' \
    -e 's|^(sessionFactoryAccessHistory\.hibernateProperties\.hibernate\.dialect=.*)$|#\1|' \
    "${PROPS}"

cat >> "${PROPS}" <<EOF

# ===========================================================================
# PostgreSQL configuration (generated at image build)
# ---------------------------------------------------------------------------
# Source: docker/iiq/iiq.properties.patch.sh
#
# The Quartz delegate MUST be set for PostgreSQL. Without it the
# scheduler fails (the default implementation assumes MySQL semantics).
# The hint is in the comment block of the shipped iiq.properties.
# ===========================================================================

# --- Main database ---------------------------------------------------------
dataSource.url=jdbc:postgresql://${DB_HOST}:${DB_PORT}/identityiq
dataSource.driverClassName=org.postgresql.Driver
dataSource.username=${IIQ_DB_USER}
dataSource.password=${IIQ_DB_PASSWORD}
sessionFactory.hibernateProperties.hibernate.dialect=sailpoint.persistence.PostgreSQL10Dialect

# --- Quartz scheduler ------------------------------------------------------
scheduler.quartzProperties.org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.PostgreSQLDelegate

# --- Plugin database -------------------------------------------------------
pluginsDataSource.url=jdbc:postgresql://${DB_HOST}:${DB_PORT}/identityiqPlugin
pluginsDataSource.driverClassName=org.postgresql.Driver
pluginsDataSource.username=${IIQ_PLUGIN_DB_USER}
pluginsDataSource.password=${IIQ_PLUGIN_DB_PASSWORD}

# --- Access History --------------------------------------------------------
dataSourceAccessHistory.url=jdbc:postgresql://${DB_HOST}:${DB_PORT}/identityiqah
dataSourceAccessHistory.driverClassName=org.postgresql.Driver
dataSourceAccessHistory.username=${IIQ_AH_DB_USER}
dataSourceAccessHistory.password=${IIQ_AH_DB_PASSWORD}
sessionFactoryAccessHistory.hibernateProperties.hibernate.dialect=sailpoint.persistence.PostgreSQL10Dialect
EOF

echo "[iiq.properties] Result:"
grep -E "^(dataSource|pluginsDataSource|dataSourceAccessHistory)\.(url|username|driverClassName)=|^sessionFactory.*dialect=|^scheduler\.quartzProperties" "${PROPS}" \
    | sed 's/^/    /'

echo "[iiq.properties] Done."
