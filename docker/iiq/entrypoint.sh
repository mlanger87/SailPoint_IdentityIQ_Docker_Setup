#!/bin/bash
# ===========================================================================
# Entrypoint for the IdentityIQ container.
#
# Two modes, selected via the INIT environment variable:
#
#   INIT=y   Init container. Waits for the database, imports the base
#            configuration (if needed), applies patch, custom objects and
#            plugins - then exits with code 0.
#
#   else     Application server. Starts Tomcat only.
#
# Why the split (pattern from reference project C):
# The import must run exactly once. A separate init container plus
# "depends_on: condition: service_completed_successfully" models that
# cleanly - and stays correct if several IIQ nodes run in parallel later.
#
# Idempotency does NOT hinge on a marker file (reference project A does
# that, which breaks on volume swaps and rebuilds) but is checked directly
# in the database.
# ===========================================================================
set -euo pipefail

SPHOME="${SPHOME:-/usr/local/tomcat/webapps/identityiq}"
IIQ_BIN="${SPHOME}/WEB-INF/bin/iiq"

DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-180}"

log() { echo "[iiq-entrypoint] $*"; }

# ---------------------------------------------------------------------------
# Wait for the database
# ---------------------------------------------------------------------------
wait_for_db() {
    log "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT} (max ${DB_WAIT_TIMEOUT}s)"
    local waited=0
    until pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -q; do
        if [ "${waited}" -ge "${DB_WAIT_TIMEOUT}" ]; then
            log "ERROR: database not reachable after ${DB_WAIT_TIMEOUT}s."
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "Database reachable (after ${waited}s)."
}

# ---------------------------------------------------------------------------
# Run several console commands in ONE JVM start.
#
# Every "iiq console" invocation costs 10-20s of Hibernate startup.
# Reference project A starts 8 JVMs in sequence - needlessly slow.
#
# IMPORTANT: "quit" MUST come last. The console does not exit on a bare
# EOF on stdin; it keeps waiting for input and the container hangs
# indefinitely. (Exactly that happened on the first test run here:
# 10 minutes idle at 43 % CPU.)
#
# Input comes via stdin; "quit" is appended automatically.
iiq_console() {
    { cat; printf '\nquit\n'; } | "${IIQ_BIN}" console
}

# ---------------------------------------------------------------------------
# Like iiq_console, but with error detection.
#
# Background: "iiq console" returns exit code 0 EVEN for a failed
# command. A botched import would otherwise pass unnoticed and the server
# would start against a half-initialized database.
#
# So the output is captured and scanned for error signatures. Reference
# project B has neither "set -e" nor any check here - errors surface only
# later.
# ---------------------------------------------------------------------------
iiq_console_checked() {
    local label="$1"
    local out rc=0

    out="$(iiq_console 2>&1)" || rc=$?

    echo "${out}"

    # The patterns are deliberately narrow.
    #
    # A pattern that is too broad is dangerous here: on a match this
    # function returns 1, the init container exits with an error because
    # of "set -e", and "iiq" never starts because of
    # "condition: service_completed_successfully". A false positive
    # therefore blocks the entire stack.
    #
    # So do NOT match bare "Exception" or "Unable to": both occur in
    # harmless messages (e.g. "Unable to find localized message for
    # key ..."). Instead match patterns that indicate a real abort:
    #
    #   ^Error:              console error message at line start
    #   ^Caused by:          exception cause chain
    #   ^\s*at sailpoint\.   stack-trace line from IIQ code
    #   java...Exception     fully qualified exception name
    if echo "${out}" | grep -qE '^Error:|^Caused by:|^[[:space:]]*at sailpoint\.|(java|javax|org|sailpoint|bsh)\.[A-Za-z.]*(Exception|Error)'; then
        log "ERROR in: ${label}"
        log "Output contains an error message (see above)."
        return 1
    fi
    return "${rc}"
}

# ---------------------------------------------------------------------------
# Import a folder of XML files in one go.
#
# Instead of N console calls, a wrapper XML with <ImportAction
# name='include'> is generated and imported once. "sort" gives a
# deterministic order - file names control import order via a prefix
# (e.g. 10-, 20-).
#
# Idea taken from reference project B (import_folder).
# ---------------------------------------------------------------------------
import_folder() {
    local folder="$1"
    local manifest="/tmp/import-$(basename "${folder}").xml"

    if [ ! -d "${folder}" ]; then
        return 0
    fi

    local count
    count=$(find "${folder}" -name '*.xml' -type f 2>/dev/null | wc -l)
    if [ "${count}" -eq 0 ]; then
        log "No XML files in ${folder} - skipped."
        return 0
    fi

    log "Importing ${count} XML file(s) from ${folder}:"
    find "${folder}" -name '*.xml' -type f | LC_ALL=C sort | sed 's|^|    |'

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE sailpoint PUBLIC "sailpoint.dtd" "sailpoint.dtd">'
        echo '<sailpoint>'
        find "${folder}" -name '*.xml' -type f | LC_ALL=C sort | while read -r f; do
            # The path lands in an XML attribute: escape & and ' or a
            # file name containing them breaks the manifest. sed, not
            # ${f//x/y}: bash 5.2 treats & in the replacement as "the match".
            f="$(printf '%s' "${f}" | sed "s/&/\\&amp;/g; s/'/\\&apos;/g")"
            echo "  <ImportAction name='include' value='${f}'/>"
        done
        echo '</sailpoint>'
    } > "${manifest}"

    echo "import ${manifest}" | iiq_console_checked "Import from ${folder}"
    log "Import from ${folder} complete."
}

# ---------------------------------------------------------------------------
# Is IdentityIQ already initialized?
#
# Checks for an object that only exists after "import init.xml". This
# reads the state where it actually lives: in the database. It therefore
# survives image rebuilds and container restarts.
# ---------------------------------------------------------------------------
is_initialized() {
    local out
    # Only ONE JVM start: capture the output once, then evaluate.
    # Deliberately not iiq_console_checked - "Unknown object" is a valid
    # result here, not an error.
    out="$(echo "get Identity spadmin" | iiq_console 2>&1 || true)"

    # Before init.xml is imported the console reports "Unknown object".
    if echo "${out}" | grep -q "Unknown object"; then
        log "State: not yet initialized."
        return 1
    fi

    # After the import, "get Identity spadmin" returns the object as XML.
    if echo "${out}" | grep -qE '<Identity|name="spadmin"'; then
        log "State: already initialized."
        return 0
    fi

    # Ambiguous output - treat as "not initialized" to be safe.
    log "State unclear, assuming 'not initialized'. Output was:"
    echo "${out}" | tail -5 | sed 's/^/    /'
    return 1
}

# ---------------------------------------------------------------------------
# Derive the patch level from the shipped README.
# Pattern from reference project B - saves a separate variable.
# ---------------------------------------------------------------------------
detect_patch_level() {
    local readme
    for readme in "${SPHOME}"/WEB-INF/config/patch/identityiq-*-README.txt; do
        [ -e "${readme}" ] || continue
        basename "${readme}" | cut -d '-' -f 2
        return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Add certificates to the Java truststore
# ---------------------------------------------------------------------------
# Runs in BOTH containers (init and server): the truststore lives in the
# container's writable layer, so an import done in iiq-init would never
# reach the iiq JVM. Requires cacerts to be owned by uid 1000 - the
# Dockerfile chowns it; the stock Temurin image ships it root:root 0644,
# which made every import fail silently until this was fixed.
import_certificates() {
    local cert_dir="/data/certs"
    [ -d "${cert_dir}" ] || return 0

    for cert in "${cert_dir}"/*.cer "${cert_dir}"/*.crt "${cert_dir}"/*.pem; do
        [ -e "${cert}" ] || continue
        local alias out
        alias="$(basename "${cert}")"
        log "Importing certificate ${alias} into the truststore."
        # Keep stderr: only "already exists" is tolerated; anything else
        # (unwritable store, unparsable file) must be visible and fatal.
        if out="$(keytool -importcert -noprompt -trustcacerts \
                    -alias "${alias}" -file "${cert}" \
                    -cacerts -storepass changeit 2>&1)"; then
            log "  imported."
        elif echo "${out}" | grep -q "already exists"; then
            log "  already present - skipped."
        else
            log "  FAILED: ${out}"
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------
run_init() {
    wait_for_db

    if is_initialized; then
        log "IdentityIQ is already initialized - skipping base import."
    else
        log "First initialization: importing init.xml and init-lcm.xml."
        log "(Takes several minutes - several thousand objects are created.)"
        iiq_console_checked "Base import init.xml / init-lcm.xml" <<'EOF'
import init.xml
import init-lcm.xml
EOF
        log "Base import complete."

        # Patch AFTER the base import - this order is mandatory.
        local patch_level=""
        if patch_level="$(detect_patch_level)"; then
            log "Applying database patch ${patch_level}."
            "${IIQ_BIN}" patch "${patch_level}"
        else
            log "No patch detected."
        fi

        # SERI and Accelerator Pack, if included in the package.
        if [ -d "${SPHOME}/WEB-INF/config/seri" ]; then
            log "SERI detected - importing init-seri.xml."
            echo "import seri/init-seri.xml" | iiq_console_checked "SERI import"
        fi
        if [ -f "${SPHOME}/WEB-INF/config/init-acceleratorpack.xml" ]; then
            log "Accelerator Pack detected - importing init-acceleratorpack.xml."
            echo "import init-acceleratorpack.xml" | iiq_console_checked "Accelerator Pack"
        fi
    fi

    # Import custom objects on EVERY init run.
    # This is the dev loop: edit XML in data/objects,
    # "docker compose up iiq-init" - done, no rebuild needed.
    import_folder /data/objects

    # Install plugins.
    #
    # Through the console: the Launcher has no "plugin" application
    # (only schema/patch/console/encrypt/...), so the earlier
    # `iiq "plugin install <zip>"` failed on every ZIP and `|| log`
    # swallowed it. The console command exists (`help plugin`) and its
    # output is checked like every other import.
    for plugin in /data/plugins/*.zip; do
        [ -e "${plugin}" ] || continue
        log "Installing plugin $(basename "${plugin}")."
        echo "plugin install ${plugin}" \
            | iiq_console_checked "Plugin $(basename "${plugin}")"
    done

    log "Initialization complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "SPHOME=${SPHOME}"
log "Java: $(java -version 2>&1 | head -1)"

import_certificates

if [ "${INIT:-}" = "y" ]; then
    log "Mode: INIT (one-time initialization)"
    run_init
    log "Init container exiting as planned."
    exit 0
fi

log "Mode: application server"
# Per-node JVM options. The shared CATALINA_OPTS block in docker-compose.yml
# carries everything that is identical on every node; the server name
# (-Diiq.hostname -> name of the Server object, and what the
# ServiceDefinition "hosts" lists refer to) and the heap are appended here
# from the node's own environment.
IIQ_NODE="${IIQ_NODE:-iiq-dev}"
export CATALINA_OPTS="${CATALINA_OPTS:-} -Xmx${IIQ_HEAP:-4g} -Diiq.hostname=${IIQ_NODE}"
log "Node: ${IIQ_NODE} (heap ${IIQ_HEAP:-4g})"
wait_for_db
exec "$@"
