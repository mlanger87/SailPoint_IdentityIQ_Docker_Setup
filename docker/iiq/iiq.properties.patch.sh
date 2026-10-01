#!/bin/bash
# ===========================================================================
# Points iiq.properties at the repository database.
#
# Runs at BUILD time on the unpacked webapp. IIQ_DB_TYPE selects the
# block: postgresql (default) or sqlserver. Host and port follow from the
# type - they are the compose service names, nothing else ever needed to
# differ - and the entrypoint reads them back from dataSource.url for its
# wait, so this file is the single source.
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

IIQ_DB_TYPE="${IIQ_DB_TYPE:-postgresql}"
IIQ_DB_USER="${IIQ_DB_USER:-identityiq}"
IIQ_DB_PASSWORD="${IIQ_DB_PASSWORD:-identityiq}"
IIQ_PLUGIN_DB_USER="${IIQ_PLUGIN_DB_USER:-identityiqPlugin}"
IIQ_PLUGIN_DB_PASSWORD="${IIQ_PLUGIN_DB_PASSWORD:-identityiqPlugin}"
IIQ_AH_DB_USER="${IIQ_AH_DB_USER:-identityiqah}"
IIQ_AH_DB_PASSWORD="${IIQ_AH_DB_PASSWORD:-identityiqah}"

# Values per repository type, all taken from the commented samples in the
# shipped iiq.properties (lines "##### MSSQL Server #####" and
# "##### PostgreSQL #####"), plus the URL options noted below.
case "${IIQ_DB_TYPE}" in
    postgresql)
        DB_LABEL="PostgreSQL"
        DRIVER="org.postgresql.Driver"
        DIALECT="sailpoint.persistence.PostgreSQL10Dialect"
        # Mandatory for PostgreSQL: the default delegate assumes MySQL
        # semantics and the scheduler fails.
        QUARTZ_DELEGATE="org.quartz.impl.jdbcjobstore.PostgreSQLDelegate"
        url() { echo "jdbc:postgresql://postgres:5432/$1"; }
        ;;
    sqlserver)
        DB_LABEL="SQL Server"
        DRIVER="com.microsoft.sqlserver.jdbc.SQLServerDriver"
        # The Unicode dialect matches the nvarchar columns of SailPoint's
        # SQL Server DDL; it is the one the shipped sample names.
        DIALECT="sailpoint.persistence.SQLServerUnicodeDialect"
        QUARTZ_DELEGATE="org.quartz.impl.jdbcjobstore.MSSQLDelegate"
        # encrypt=false: mssql-jdbc 10+ encrypts by default and rejects
        # the container's self-signed certificate. Traffic stays on the
        # compose bridge network.
        url() { echo "jdbc:sqlserver://mssql:1433;databaseName=$1;encrypt=false"; }
        ;;
    *)
        echo "[iiq.properties] ERROR: IIQ_DB_TYPE='${IIQ_DB_TYPE}' - expected postgresql or sqlserver." >&2
        exit 1
        ;;
esac

echo "[iiq.properties] Switching to ${DB_LABEL} ($(url identityiq))"

if [ ! -f "${PROPS}" ]; then
    echo "[iiq.properties] ERROR: ${PROPS} not found." >&2
    exit 1
fi

cp "${PROPS}" "${PROPS}.orig"

# ---------------------------------------------------------------------------
# Comment out every database-related line pointing at MySQL, then append
# a clean block for the selected database. Appended values win, since iiq.properties
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
# ${DB_LABEL} configuration (generated at image build, IIQ_DB_TYPE=${IIQ_DB_TYPE})
# ---------------------------------------------------------------------------
# Source: docker/iiq/iiq.properties.patch.sh
# ===========================================================================

# --- Main database ---------------------------------------------------------
dataSource.url=$(url identityiq)
dataSource.driverClassName=${DRIVER}
dataSource.username=${IIQ_DB_USER}
dataSource.password=${IIQ_DB_PASSWORD}
sessionFactory.hibernateProperties.hibernate.dialect=${DIALECT}

# --- Quartz scheduler ------------------------------------------------------
scheduler.quartzProperties.org.quartz.jobStore.driverDelegateClass=${QUARTZ_DELEGATE}

# --- Plugin database -------------------------------------------------------
pluginsDataSource.url=$(url identityiqPlugin)
pluginsDataSource.driverClassName=${DRIVER}
pluginsDataSource.username=${IIQ_PLUGIN_DB_USER}
pluginsDataSource.password=${IIQ_PLUGIN_DB_PASSWORD}

# --- Access History --------------------------------------------------------
dataSourceAccessHistory.url=$(url identityiqah)
dataSourceAccessHistory.driverClassName=${DRIVER}
dataSourceAccessHistory.username=${IIQ_AH_DB_USER}
dataSourceAccessHistory.password=${IIQ_AH_DB_PASSWORD}
sessionFactoryAccessHistory.hibernateProperties.hibernate.dialect=${DIALECT}
EOF

echo "[iiq.properties] Result:"
grep -E "^(dataSource|pluginsDataSource|dataSourceAccessHistory)\.(url|username|driverClassName)=|^sessionFactory.*dialect=|^scheduler\.quartzProperties" "${PROPS}" \
    | sed 's/^/    /'

echo "[iiq.properties] Done."
