# ===========================================================================
# SailPoint IdentityIQ 8.5 auf Tomcat 9 / OpenJDK 21
# ---------------------------------------------------------------------------
# Versionswahl (belegt im mitgelieferten Installation Guide, doc/):
#
#   Tomcat 9  - ZWINGEND. Der Guide listet unter "Application Servers" nur
#               Apache Tomcat 9.0. Technisch bestaetigt: die Webapp ist
#               javax.servlet-basiert (web-app 2.5, javax.faces 2.2.20,
#               Spring 5.3, Hibernate 5.5). Tomcat 10/11 nutzen den
#               jakarta.*-Namensraum - das WAR wuerde dort nicht starten.
#
#   JDK 21    - Offiziell unterstuetzt: "OpenJDK 21 and 17 is now supported
#               on all environments" (Guide, Supported Platforms). Der
#               Bytecode selbst ist auf Java 11 kompiliert (major 55) und
#               laeuft abwaertskompatibel.
#
# Das WAR ist 742 MB gross und entpackt sich auf ~1 GB in 8.984 Dateien
# (davon allein 562 MB Connector-Bundles). Deshalb Multi-Stage: das ZIP
# und die Zwischenstaende landen nicht im finalen Image.
# ===========================================================================

# ---------------------------------------------------------------------------
# Stage 1: Installationspaket entpacken und aufbereiten
# ---------------------------------------------------------------------------
FROM tomcat:9.0-jdk21-temurin AS extract

ARG IIQ_VERSION=8.5
ARG IIQ_PATCH=""
ARG PG_JDBC_VERSION=42.7.5

ARG DB_HOST=postgres
ARG DB_PORT=5432
ARG IIQ_DB_USER=identityiq
ARG IIQ_DB_PASSWORD=identityiq
ARG IIQ_PLUGIN_DB_USER=identityiqPlugin
ARG IIQ_PLUGIN_DB_PASSWORD=identityiqPlugin
ARG IIQ_AH_DB_USER=identityiqah
ARG IIQ_AH_DB_PASSWORD=identityiqah

ENV SPHOME=/opt/iiq/identityiq

RUN apt-get update \
 && apt-get install -y --no-install-recommends unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Den gesamten installer/-Ordner uebernehmen. Er enthaelt das
# Installationspaket und - optional - ein Patch-JAR.
COPY installer/ /build/installer/

# Nur identityiq.war herausziehen - nicht doc/, integration/ usw.
RUN set -eux \
 && PKG="$(find /build/installer -maxdepth 1 -name '*.zip' | head -1)" \
 && test -n "${PKG}" \
 && unzip -j -o "${PKG}" identityiq.war -d /build

# Entpacken mit "jar" statt "unzip": das JDK-Werkzeug ist im Image
# ohnehin vorhanden (Idee aus Referenzprojekt B).
# Das WAR wird danach geloescht - sonst laegen ~740 MB doppelt im Layer.
RUN mkdir -p "${SPHOME}" \
 && cd "${SPHOME}" \
 && jar -xf /build/identityiq.war \
 && chmod +x "${SPHOME}/WEB-INF/bin/iiq"

# --- Patch-JAR (optional) --------------------------------------------------
# Ein Patch wird ueber das entpackte Verzeichnis gelegt. Die zugehoerigen
# DB-Upgrades und "iiq patch" laufen spaeter im Init-Container.
#
# Das Patch-JAR wird - falls vorhanden - in den Ordner installer/ gelegt
# und ueber IIQ_PATCH (z.B. "p1") aktiviert. Liegt kein Patch vor, bleibt
# IIQ_PATCH leer und dieser Schritt ist ein No-op.
#
# Das JAR liegt bereits unter /build/installer (siehe COPY oben), es ist
# also kein weiteres COPY noetig.
COPY docker/iiq/apply-patch.sh /tmp/apply-patch.sh
RUN chmod +x /tmp/apply-patch.sh \
 && /tmp/apply-patch.sh "${SPHOME}" "${IIQ_VERSION}" "${IIQ_PATCH}" \
 && rm -rf /build/installer /build/identityiq.war /tmp/apply-patch.sh

# --- PostgreSQL-JDBC-Treiber ----------------------------------------------
# Der Guide stellt klar: "The JDBC driver for PostgreSQL is not provided
# with IdentityIQ." Im WAR liegt nur mysql-connector-j. Der Treiber wird
# deshalb hier nachgelegt.
ADD --chmod=644 \
    https://repo1.maven.org/maven2/org/postgresql/postgresql/${PG_JDBC_VERSION}/postgresql-${PG_JDBC_VERSION}.jar \
    ${SPHOME}/WEB-INF/lib/postgresql-${PG_JDBC_VERSION}.jar

# --- iiq.properties auf PostgreSQL umstellen ------------------------------
COPY docker/iiq/iiq.properties.patch.sh /tmp/patch-props.sh
RUN DB_HOST="${DB_HOST}" DB_PORT="${DB_PORT}" \
    IIQ_DB_USER="${IIQ_DB_USER}" IIQ_DB_PASSWORD="${IIQ_DB_PASSWORD}" \
    IIQ_PLUGIN_DB_USER="${IIQ_PLUGIN_DB_USER}" IIQ_PLUGIN_DB_PASSWORD="${IIQ_PLUGIN_DB_PASSWORD}" \
    IIQ_AH_DB_USER="${IIQ_AH_DB_USER}" IIQ_AH_DB_PASSWORD="${IIQ_AH_DB_PASSWORD}" \
    /tmp/patch-props.sh "${SPHOME}/WEB-INF/classes/iiq.properties" \
 && rm -f /tmp/patch-props.sh

# ---------------------------------------------------------------------------
# Stage 2: Laufzeit-Image
# ---------------------------------------------------------------------------
FROM tomcat:9.0-jdk21-temurin AS runtime

LABEL org.opencontainers.image.title="SailPoint IdentityIQ 8.5" \
      org.opencontainers.image.description="IdentityIQ 8.5 auf Tomcat 9 / OpenJDK 21 mit PostgreSQL" \
      org.opencontainers.image.vendor="intern"

ENV SPHOME=/usr/local/tomcat/webapps/identityiq \
    CATALINA_HOME=/usr/local/tomcat

# gettext-base liefert envsubst, postgresql-client liefert pg_isready
# (fuer das Warten auf die Datenbank im Init-Container).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        gettext-base \
        postgresql-client \
 && rm -rf /var/lib/apt/lists/*

# --- Alles Kleinteilige VOR dem grossen COPY -------------------------------
# Reihenfolge ist hier wichtig fuer das Layer-Caching: die Webapp-Schicht
# ist rund 1 GB gross. Laege sie vor den Skripten, wuerde jede Aenderung
# am entrypoint.sh einen kompletten Neuaufbau dieser Schicht ausloesen.

# UTF-8 am Connector. Ohne das kommt es bei Umlauten in Identity-Attributen
# und URLs zu Fehldarstellungen - ein klassischer IIQ-Stolperstein.
RUN sed -i 's|<Connector |<Connector URIEncoding="UTF-8" |g' \
        ${CATALINA_HOME}/conf/server.xml \
 && grep -c 'URIEncoding="UTF-8"' ${CATALINA_HOME}/conf/server.xml

# Bequemer Zugriff auf die IIQ-Kommandozeile:
#   docker compose exec iiq iiq console
RUN ln -sf ${SPHOME}/WEB-INF/bin/iiq /usr/local/bin/iiq \
 && printf '#!/bin/sh\nexec %s/WEB-INF/bin/iiq console "$@"\n' "${SPHOME}" \
        > /usr/local/bin/iiq-console \
 && chmod +x /usr/local/bin/iiq-console \
 && mkdir -p /data/objects /data/plugins /data/certs \
 && chown -R 1000:1000 /data ${CATALINA_HOME}

COPY --chmod=755 docker/iiq/entrypoint.sh   /opt/entrypoint.sh
COPY --chmod=755 docker/iiq/healthcheck.sh  /opt/healthcheck.sh

# --- Die grosse Schicht zuletzt -------------------------------------------
# --chown vermeidet ein nachgelagertes "chown -R" ueber 8.984 Dateien,
# das die komplette Schicht noch einmal duplizieren wuerde.
COPY --from=extract --chown=1000:1000 /opt/iiq/identityiq ${SPHOME}

# Non-root (Vorbild: Referenzprojekt D; die anderen drei laufen als root).
# Die UID 1000 passt zum Standard-Benutzer vieler Linux-Hosts und
# vermeidet Rechteprobleme bei Bind-Mounts.
RUN groupadd -g 1000 iiq 2>/dev/null || true \
 && useradd -u 1000 -g 1000 -d ${CATALINA_HOME} -s /bin/bash iiq 2>/dev/null || true
USER 1000:1000

EXPOSE 8080

HEALTHCHECK --start-period=180s --interval=15s --timeout=10s --retries=20 \
    CMD /opt/healthcheck.sh

ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["catalina.sh", "run"]
