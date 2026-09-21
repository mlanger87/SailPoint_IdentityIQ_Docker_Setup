# ===========================================================================
# PostgreSQL 17 mit vorbereitetem IdentityIQ-Schema
# ---------------------------------------------------------------------------
# Das Schema wird NICHT zur Laufzeit von einem SQL-Client im App-Container
# angelegt (so machen es die Referenzprojekte A und D), sondern ueber den
# nativen Mechanismus /docker-entrypoint-initdb.d des offiziellen
# Postgres-Images. Vorteile: laeuft genau einmal (wenn das Datenverzeichnis
# leer ist), braucht keinen Marker, und der App-Container bleibt frei von
# Datenbank-Werkzeugen.
#
# Besonderheit der SailPoint-PostgreSQL-DDL (verifiziert am Paket 8.5):
#   - Sie legt ALLE drei Datenbanken selbst an (identityiq, identityiqah,
#     identityiqPlugin) inkl. der drei Benutzer.
#     => POSTGRES_DB darf deshalb NICHT gesetzt werden.
#   - Sie enthaelt 9 psql-Meta-Kommandos (\connect), um zwischen den
#     Datenbanken zu wechseln.
#     => Sie muss von psql ausgefuehrt werden, nicht ueber einen
#        generischen JDBC-/SQL-Treiber.
#   - Case-insensitive Suche wird ueber 244 Funktionsindizes auf upper()
#     geloest. Es ist also KEINE spezielle Collation noetig.
# ===========================================================================

# ---------------------------------------------------------------------------
# Stage 1: DDL aus dem Installationspaket holen und parametrisieren
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS ddl

# Hinweis zu den Passwort-ARGs (Linter-Warnung docker:S6472):
# Das ist hier bewusst in Kauf genommen. Die DDL von SailPoint legt die
# Datenbankbenutzer per "CREATE USER ... ENCRYPTED PASSWORD" an; die
# Passwoerter muessen also zur Build-Zeit in die SQL-Datei. Sie landen
# dadurch in der Build-History dieser Zwischen-Stage.
#
# Fuer eine lokale Entwicklungsumgebung ist das vertretbar - die Werte
# stehen ohnehin in der .env und die DB ist nicht exponiert.
# Fuer eine Produktivumgebung waere stattdessen der Weg ueber
# BuildKit-Secrets (RUN --mount=type=secret) bzw. ein nachgelagertes
# ALTER USER aus einem Docker-Secret zu waehlen.
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

# Das Installationspaket wird aus installer/ in den Build-Kontext gereicht.
COPY installer/*.zip /work/package.zip

# Nur die benoetigte DDL entpacken - nicht das ganze 770-MB-Paket.
RUN unzip -j -o /work/package.zip \
        "database/create_identityiq_tables-${IIQ_VERSION}.postgresql" \
        -d /work/extracted \
 && mv /work/extracted/create_identityiq_tables-${IIQ_VERSION}.postgresql \
       /work/extracted/01-create-identityiq.sql

# Die von SailPoint ausgelieferte DDL enthaelt die Default-Passwoerter fest
# verdrahtet (CREATE USER identityiq WITH ENCRYPTED PASSWORD 'identityiq').
# Sie werden hier durch die Werte aus der .env ersetzt.
# Dieses Muster stammt aus Referenzprojekt C (database-setup.mssql.sh).
#
# Gezielt nur die CREATE-USER-Zeilen anfassen, damit keine gleichnamigen
# Bezeichner an anderer Stelle der 9.146-Zeilen-Datei getroffen werden.
RUN cd /work/extracted \
 && sed -i \
      -e "s|^CREATE USER identityiq WITH ENCRYPTED PASSWORD 'identityiq';|CREATE USER ${IIQ_DB_USER} WITH ENCRYPTED PASSWORD '${IIQ_DB_PASSWORD}';|" \
      -e "s|^CREATE USER \"identityiqPlugin\" WITH ENCRYPTED PASSWORD 'identityiqPlugin';|CREATE USER \"${IIQ_PLUGIN_DB_USER}\" WITH ENCRYPTED PASSWORD '${IIQ_PLUGIN_DB_PASSWORD}';|" \
      -e "s|^CREATE USER identityiqah WITH ENCRYPTED PASSWORD 'identityiqah';|CREATE USER ${IIQ_AH_DB_USER} WITH ENCRYPTED PASSWORD '${IIQ_AH_DB_PASSWORD}';|" \
      01-create-identityiq.sql \
 && echo "--- Kontrolle: erzeugte CREATE-USER-Zeilen ---" \
 && grep -n "^CREATE USER" 01-create-identityiq.sql

# ---------------------------------------------------------------------------
# Stage 2: Laufzeit-Image
# ---------------------------------------------------------------------------
FROM postgres:17-bookworm

# Wird beim ersten Start automatisch von psql ausgefuehrt (alphabetisch).
COPY --from=ddl /work/extracted/01-create-identityiq.sql \
                /docker-entrypoint-initdb.d/01-create-identityiq.sql

# Setzt den search_path auf die IIQ-Schemata, damit Tabellen auch ohne
# Schema-Praefix gefunden werden (Adminer, psql, eigene Auswertungen).
# Muss NACH der Schema-DDL laufen - daher Praefix 02.
COPY docker/postgres/02-search-path.sql \
     /docker-entrypoint-initdb.d/02-search-path.sql

# Vierte Datenbank als Zielsystem fuer den JDBC-Connector. Bewusst im
# selben Container: der PostgreSQL-JDBC-Treiber liegt bereits im
# IIQ-Image, ein zweites Datenbanksystem haette keinen Erkenntniswert.
COPY docker/postgres/03-targetdb.sql \
     /docker-entrypoint-initdb.d/03-targetdb.sql

# Tuning fuer IdentityIQ.
#
# "include_dir" laesst sich NICHT per "postgres -c" setzen (es ist nur in
# einer Konfigurationsdatei gueltig, sonst: FATAL unrecognized
# configuration parameter). Das Tuning wird deshalb als initdb-Hook an die
# vom Entrypoint erzeugte postgresql.conf angehaengt.
#
# Skripte in /docker-entrypoint-initdb.d laufen alphabetisch; der
# 00-Praefix stellt sicher, dass die Konfiguration vor der DDL greift.
COPY docker/postgres/postgresql.tuning.conf /opt/iiq/postgresql.tuning.conf
COPY docker/postgres/00-apply-tuning.sh     /docker-entrypoint-initdb.d/00-apply-tuning.sh
