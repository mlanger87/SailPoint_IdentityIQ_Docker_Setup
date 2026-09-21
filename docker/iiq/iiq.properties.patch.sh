#!/bin/bash
# ===========================================================================
# Stellt iiq.properties auf PostgreSQL um.
#
# Laeuft zur BUILD-Zeit auf der entpackten Webapp.
#
# Warum gezieltes Patchen statt einer kompletten Ersatzdatei:
# Die ausgelieferte iiq.properties hat ueber 400 Zeilen und enthaelt
# neben den DataSources sehr viele weitere Einstellungen (Rule-Pools,
# Hibernate-Listener, Task-Threads ...). Eine eigene Vollversion muesste
# bei jedem IIQ-Upgrade nachgezogen werden. Deshalb werden nur die
# datenbankspezifischen Schluessel ersetzt.
#
# Referenzprojekt A macht hier ein globales "sed s/localhost/host/g" -
# das trifft auch Nicht-DataSource-Schluessel. Hier wird jeder Schluessel
# einzeln und verankert (^) ersetzt.
# ===========================================================================
set -euo pipefail

PROPS="${1:?Pfad zu iiq.properties fehlt}"

DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
IIQ_DB_USER="${IIQ_DB_USER:-identityiq}"
IIQ_DB_PASSWORD="${IIQ_DB_PASSWORD:-identityiq}"
IIQ_PLUGIN_DB_USER="${IIQ_PLUGIN_DB_USER:-identityiqPlugin}"
IIQ_PLUGIN_DB_PASSWORD="${IIQ_PLUGIN_DB_PASSWORD:-identityiqPlugin}"
IIQ_AH_DB_USER="${IIQ_AH_DB_USER:-identityiqah}"
IIQ_AH_DB_PASSWORD="${IIQ_AH_DB_PASSWORD:-identityiqah}"

echo "[iiq.properties] Stelle auf PostgreSQL um (${DB_HOST}:${DB_PORT})"

if [ ! -f "${PROPS}" ]; then
    echo "[iiq.properties] FEHLER: ${PROPS} nicht gefunden." >&2
    exit 1
fi

cp "${PROPS}" "${PROPS}.orig"

# ---------------------------------------------------------------------------
# Alle datenbankbezogenen Zeilen auskommentieren, die auf MySQL zeigen.
# Anschliessend wird ein sauberer PostgreSQL-Block angehaengt. Angehaengte
# Werte gewinnen, da iiq.properties spaeter gelesene Schluessel bevorzugt.
# Dieses Muster stammt aus Referenzprojekt C (configureMssqlProperties).
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
# PostgreSQL-Konfiguration (automatisch erzeugt beim Image-Build)
# ---------------------------------------------------------------------------
# Belegt in: docker/iiq/iiq.properties.patch.sh
#
# Wichtig: Der Quartz-Delegate MUSS bei PostgreSQL gesetzt werden. Ohne
# ihn schlaegt der Scheduler fehl (die Standard-Implementierung setzt
# MySQL-Semantik voraus). Der Hinweis dazu steht im Kommentarblock der
# ausgelieferten iiq.properties.
# ===========================================================================

# --- Hauptdatenbank --------------------------------------------------------
dataSource.url=jdbc:postgresql://${DB_HOST}:${DB_PORT}/identityiq
dataSource.driverClassName=org.postgresql.Driver
dataSource.username=${IIQ_DB_USER}
dataSource.password=${IIQ_DB_PASSWORD}
sessionFactory.hibernateProperties.hibernate.dialect=sailpoint.persistence.PostgreSQL10Dialect

# --- Quartz-Scheduler ------------------------------------------------------
scheduler.quartzProperties.org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.PostgreSQLDelegate

# --- Plugin-Datenbank ------------------------------------------------------
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

echo "[iiq.properties] Ergebnis:"
grep -E "^(dataSource|pluginsDataSource|dataSourceAccessHistory)\.(url|username|driverClassName)=|^sessionFactory.*dialect=|^scheduler\.quartzProperties" "${PROPS}" \
    | sed 's/^/    /'

echo "[iiq.properties] Fertig."
