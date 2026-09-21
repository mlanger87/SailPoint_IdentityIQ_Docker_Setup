# ===========================================================================
# SailPoint IdentityIQ 8.5 on Tomcat 9 / OpenJDK 21
# ---------------------------------------------------------------------------
# Version choice (verified against the shipped Installation Guide, doc/):
#
#   Tomcat 9  - MANDATORY. Under "Application Servers" the Guide lists only
#               Apache Tomcat 9.0. Confirmed technically: the webapp is
#               javax.servlet-based (web-app 2.5, javax.faces 2.2.20,
#               Spring 5.3, Hibernate 5.5). Tomcat 10/11 use the jakarta.*
#               namespace - the WAR would not start there.
#
#   JDK 21    - Officially supported: "OpenJDK 21 and 17 is now supported
#               on all environments" (Guide, Supported Platforms). The
#               bytecode itself targets Java 11 (major 55) and runs
#               backward-compatibly.
#
# The WAR is 742 MB and unpacks to ~1 GB in 8,984 files (562 MB of which
# are connector bundles). Hence multi-stage: the ZIP and intermediate
# states do not end up in the final image.
# ===========================================================================

# ---------------------------------------------------------------------------
# Stage 1: unpack and prepare the installation package
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

# Copy the whole installer/ folder: installation package plus an
# optional patch JAR.
COPY installer/ /build/installer/

# Extract identityiq.war only - not doc/, integration/ etc.
RUN set -eux \
 && PKG="$(find /build/installer -maxdepth 1 -name '*.zip' | head -1)" \
 && test -n "${PKG}" \
 && unzip -j -o "${PKG}" identityiq.war -d /build

# Unpack with "jar" instead of "unzip": the JDK tool is already in the
# image (idea from reference project B).
# The WAR is deleted afterwards - otherwise ~740 MB would sit twice in
# the layer.
RUN mkdir -p "${SPHOME}" \
 && cd "${SPHOME}" \
 && jar -xf /build/identityiq.war \
 && chmod +x "${SPHOME}/WEB-INF/bin/iiq"

# --- Patch JAR (optional) --------------------------------------------------
# A patch is laid over the unpacked directory. The corresponding DB
# upgrades and "iiq patch" run later in the init container.
#
# The patch JAR - if present - goes into installer/ and is activated via
# IIQ_PATCH (e.g. "p1"). With no patch, IIQ_PATCH stays empty and this
# step is a no-op.
#
# The JAR is already under /build/installer (see COPY above), so no
# further COPY is needed.
COPY docker/iiq/apply-patch.sh /tmp/apply-patch.sh
RUN chmod +x /tmp/apply-patch.sh \
 && /tmp/apply-patch.sh "${SPHOME}" "${IIQ_VERSION}" "${IIQ_PATCH}" \
 && rm -rf /build/installer /build/identityiq.war /tmp/apply-patch.sh

# --- PostgreSQL JDBC driver ------------------------------------------------
# The Guide is explicit: "The JDBC driver for PostgreSQL is not provided
# with IdentityIQ." The WAR only ships mysql-connector-j, so the driver
# is added here.
# --checksum: HTTPS only proves we talked to repo1. A republished or
# mirrored artifact would otherwise swap the driver - the code every DB
# byte passes through - on the next build without any signal. SHA-256
# computed from the jar and cross-checked against Maven Central's
# published .sha1 (747897987b86c741fb8b56f6b81929ae1e6e4b46).
# Bumping PG_JDBC_VERSION requires updating this hash.
ADD --checksum=sha256:69020b3bd20984543e817393f2e6c01a890ef2e37a77dd11d6d8508181d079ab \
    --chmod=644 \
    https://repo1.maven.org/maven2/org/postgresql/postgresql/${PG_JDBC_VERSION}/postgresql-${PG_JDBC_VERSION}.jar \
    ${SPHOME}/WEB-INF/lib/postgresql-${PG_JDBC_VERSION}.jar

# --- Switch iiq.properties to PostgreSQL -----------------------------------
COPY docker/iiq/iiq.properties.patch.sh /tmp/patch-props.sh
RUN DB_HOST="${DB_HOST}" DB_PORT="${DB_PORT}" \
    IIQ_DB_USER="${IIQ_DB_USER}" IIQ_DB_PASSWORD="${IIQ_DB_PASSWORD}" \
    IIQ_PLUGIN_DB_USER="${IIQ_PLUGIN_DB_USER}" IIQ_PLUGIN_DB_PASSWORD="${IIQ_PLUGIN_DB_PASSWORD}" \
    IIQ_AH_DB_USER="${IIQ_AH_DB_USER}" IIQ_AH_DB_PASSWORD="${IIQ_AH_DB_PASSWORD}" \
    /tmp/patch-props.sh "${SPHOME}/WEB-INF/classes/iiq.properties" \
 && rm -f /tmp/patch-props.sh

# ---------------------------------------------------------------------------
# Stage 2: runtime image
# ---------------------------------------------------------------------------
FROM tomcat:9.0-jdk21-temurin AS runtime

LABEL org.opencontainers.image.title="SailPoint IdentityIQ 8.5" \
      org.opencontainers.image.description="IdentityIQ 8.5 on Tomcat 9 / OpenJDK 21 with PostgreSQL" \
      org.opencontainers.image.vendor="internal"

ENV SPHOME=/usr/local/tomcat/webapps/identityiq \
    CATALINA_HOME=/usr/local/tomcat

# gettext-base provides envsubst, postgresql-client provides pg_isready
# (for the DB wait in the init container).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        gettext-base \
        postgresql-client \
 && rm -rf /var/lib/apt/lists/*

# --- Everything small BEFORE the big COPY ----------------------------------
# Order matters for layer caching: the webapp layer is ~1 GB. If it came
# before the scripts, every change to entrypoint.sh would trigger a full
# rebuild of that layer.

# UTF-8 on the connector. Without it, umlauts in identity attributes and
# URLs render incorrectly - a classic IIQ pitfall.
RUN sed -i 's|<Connector |<Connector URIEncoding="UTF-8" |g' \
        ${CATALINA_HOME}/conf/server.xml \
 && grep -c 'URIEncoding="UTF-8"' ${CATALINA_HOME}/conf/server.xml

# Convenient access to the IIQ command line:
#   docker compose exec iiq iiq console
RUN ln -sf ${SPHOME}/WEB-INF/bin/iiq /usr/local/bin/iiq \
 && printf '#!/bin/sh\nexec %s/WEB-INF/bin/iiq console "$@"\n' "${SPHOME}" \
        > /usr/local/bin/iiq-console \
 && chmod +x /usr/local/bin/iiq-console \
 && mkdir -p /data/objects /data/plugins /data/certs \
 && chown -R 1000:1000 /data ${CATALINA_HOME} \
 # The truststore must be writable by the app user, or the certificate
 # import in entrypoint.sh fails. Temurin ships it root:root 0644 - that
 # made every import a silent no-op. Only the file, not the JDK.
 && chown 1000:1000 "${JAVA_HOME}/lib/security/cacerts"

COPY --chmod=755 docker/iiq/entrypoint.sh   /opt/entrypoint.sh
COPY --chmod=755 docker/iiq/healthcheck.sh  /opt/healthcheck.sh

# --- The big layer last ----------------------------------------------------
# --chown avoids a trailing "chown -R" over 8,984 files, which would
# duplicate the entire layer once more.
COPY --from=extract --chown=1000:1000 /opt/iiq/identityiq ${SPHOME}

# Non-root (after reference project D; the other three run as root).
# UID 1000 matches the default user on many Linux hosts and avoids
# permission issues with bind mounts.
RUN groupadd -g 1000 iiq 2>/dev/null || true \
 && useradd -u 1000 -g 1000 -d ${CATALINA_HOME} -s /bin/bash iiq 2>/dev/null || true
USER 1000:1000

EXPOSE 8080

HEALTHCHECK --start-period=180s --interval=15s --timeout=10s --retries=20 \
    CMD /opt/healthcheck.sh

ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["catalina.sh", "run"]
