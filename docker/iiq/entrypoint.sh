#!/bin/bash
# ===========================================================================
# Entrypoint fuer den IdentityIQ-Container.
#
# Zwei Betriebsarten, gesteuert ueber die Umgebungsvariable INIT:
#
#   INIT=y   Init-Container. Wartet auf die Datenbank, importiert die
#            Basiskonfiguration (falls noetig), spielt Patch, eigene
#            Objekte und Plugins ein - und beendet sich mit Code 0.
#
#   sonst    Anwendungsserver. Startet nur Tomcat.
#
# Warum diese Trennung (Muster aus Referenzprojekt C):
# Der Import darf genau einmal laufen. Mit einem separaten Init-Container
# und "depends_on: condition: service_completed_successfully" ist das
# sauber modelliert - auch dann noch, wenn spaeter mehrere IIQ-Knoten
# parallel laufen sollen.
#
# Die Idempotenz haengt NICHT an einer Markerdatei (so macht es
# Referenzprojekt A, was bei Volume-Wechseln und Rebuilds bricht),
# sondern wird direkt in der Datenbank geprueft.
# ===========================================================================
set -euo pipefail

SPHOME="${SPHOME:-/usr/local/tomcat/webapps/identityiq}"
IIQ_BIN="${SPHOME}/WEB-INF/bin/iiq"

DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-180}"

log() { echo "[iiq-entrypoint] $*"; }

# ---------------------------------------------------------------------------
# Auf die Datenbank warten
# ---------------------------------------------------------------------------
wait_for_db() {
    log "Warte auf PostgreSQL unter ${DB_HOST}:${DB_PORT} (max. ${DB_WAIT_TIMEOUT}s)"
    local waited=0
    until pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -q; do
        if [ "${waited}" -ge "${DB_WAIT_TIMEOUT}" ]; then
            log "FEHLER: Datenbank nach ${DB_WAIT_TIMEOUT}s nicht erreichbar."
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "Datenbank ist erreichbar (nach ${waited}s)."
}

# ---------------------------------------------------------------------------
# Mehrere Konsolenbefehle in EINEM JVM-Start ausfuehren.
#
# Jeder "iiq console"-Aufruf kostet 10-20s Hibernate-Startup.
# Referenzprojekt A startet 8 JVMs nacheinander - das dauert unnoetig.
#
# WICHTIG: Am Ende MUSS "quit" stehen. Die Konsole beendet sich bei
# einem reinen EOF auf stdin nicht, sondern wartet weiter auf Eingaben -
# der Container haengt dann unbegrenzt. (Genau das ist hier beim ersten
# Testlauf passiert: 10 Minuten Leerlauf bei 43 % CPU.)
#
# Die Eingabe kommt ueber stdin; "quit" wird automatisch angehaengt.
iiq_console() {
    { cat; printf '\nquit\n'; } | "${IIQ_BIN}" console
}

# ---------------------------------------------------------------------------
# Wie iiq_console, aber mit Fehlererkennung.
#
# Hintergrund: "iiq console" liefert AUCH bei einem fehlgeschlagenen
# Kommando den Exitcode 0. Ein misslungener Import wuerde sonst
# unbemerkt durchlaufen und der Server startete gegen eine
# halb-initialisierte Datenbank.
#
# Deshalb wird die Ausgabe eingesammelt und auf Fehlersignaturen
# geprueft. Referenzprojekt B hat hier kein "set -e" und keine
# Auswertung - Fehler fallen dort erst spaeter auf.
# ---------------------------------------------------------------------------
iiq_console_checked() {
    local label="$1"
    local out rc=0

    out="$(iiq_console 2>&1)" || rc=$?

    echo "${out}"

    # Die Muster sind bewusst eng gefasst.
    #
    # Ein zu breites Muster ist hier gefaehrlich: Bei einem Treffer
    # liefert diese Funktion 1, der Init-Container endet wegen "set -e"
    # mit Fehler, und "iiq" startet wegen
    # "condition: service_completed_successfully" gar nicht erst. Ein
    # False Positive blockiert also den gesamten Stack.
    #
    # Deshalb NICHT auf blosses "Exception" oder "Unable to" pruefen:
    # Beides kommt in harmlosen Meldungen vor (etwa "Unable to find
    # localized message for key ..."). Stattdessen auf Muster, die einen
    # echten Abbruch anzeigen:
    #
    #   ^Error:              Fehlermeldung der Konsole am Zeilenanfang
    #   ^Caused by:          Ursachenkette einer Ausnahme
    #   ^\s*at sailpoint\.   Stacktrace-Zeile aus IIQ-Code
    #   java...Exception     voll qualifizierter Ausnahmename
    if echo "${out}" | grep -qE '^Error:|^Caused by:|^[[:space:]]*at sailpoint\.|(java|javax|org|sailpoint|bsh)\.[A-Za-z.]*(Exception|Error)'; then
        log "FEHLER bei: ${label}"
        log "Die Ausgabe enthaelt eine Fehlermeldung (siehe oben)."
        return 1
    fi
    return "${rc}"
}

# ---------------------------------------------------------------------------
# Einen Ordner voller XML-Dateien in einem Rutsch importieren.
#
# Statt N Konsolenaufrufe wird ein Sammel-XML mit <ImportAction
# name='include'> erzeugt und einmal importiert. Das "sort" sorgt fuer
# eine deterministische Reihenfolge - Dateinamen koennen die
# Import-Reihenfolge also ueber ein Praefix steuern (z.B. 10-, 20-).
#
# Idee uebernommen aus Referenzprojekt B (import_folder).
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
        log "Keine XML-Dateien in ${folder} - uebersprungen."
        return 0
    fi

    log "Importiere ${count} XML-Datei(en) aus ${folder}:"
    find "${folder}" -name '*.xml' -type f | sort | sed 's|^|    |'

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE sailpoint PUBLIC "sailpoint.dtd" "sailpoint.dtd">'
        echo '<sailpoint>'
        find "${folder}" -name '*.xml' -type f | sort | while read -r f; do
            echo "  <ImportAction name='include' value='${f}'/>"
        done
        echo '</sailpoint>'
    } > "${manifest}"

    echo "import ${manifest}" | iiq_console_checked "Import aus ${folder}"
    log "Import aus ${folder} abgeschlossen."
}

# ---------------------------------------------------------------------------
# Ist IdentityIQ bereits initialisiert?
#
# Geprueft wird ein Objekt, das erst durch "import init.xml" entsteht.
# Diese Pruefung liest den Zustand dort, wo er tatsaechlich lebt: in der
# Datenbank. Sie ueberlebt damit Image-Rebuilds und Container-Neustarts.
# ---------------------------------------------------------------------------
is_initialized() {
    local out
    # Nur EIN JVM-Start: Ausgabe einmal einsammeln und dann auswerten.
    # Bewusst ohne iiq_console_checked - "Unknown object" ist hier ein
    # gueltiges Ergebnis und kein Fehler.
    out="$(echo "get Identity spadmin" | iiq_console 2>&1 || true)"

    # Vor dem Import von init.xml meldet die Konsole "Unknown object".
    if echo "${out}" | grep -q "Unknown object"; then
        log "Zustand: noch nicht initialisiert."
        return 1
    fi

    # Nach dem Import liefert "get Identity spadmin" das Objekt als XML.
    if echo "${out}" | grep -qE '<Identity|name="spadmin"'; then
        log "Zustand: bereits initialisiert."
        return 0
    fi

    # Unklare Ausgabe - zur Sicherheit als "nicht initialisiert" werten.
    log "Zustand unklar, gehe von 'nicht initialisiert' aus. Ausgabe war:"
    echo "${out}" | tail -5 | sed 's/^/    /'
    return 1
}

# ---------------------------------------------------------------------------
# Patch-Level automatisch aus der mitgelieferten README ableiten.
# Muster aus Referenzprojekt B - spart eine separate Variable.
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
# Zertifikate in den Java-Truststore aufnehmen
# ---------------------------------------------------------------------------
import_certificates() {
    local cert_dir="/data/certs"
    [ -d "${cert_dir}" ] || return 0

    local found=0
    for cert in "${cert_dir}"/*.cer "${cert_dir}"/*.crt "${cert_dir}"/*.pem; do
        [ -e "${cert}" ] || continue
        found=1
        local alias
        alias="$(basename "${cert}")"
        log "Importiere Zertifikat ${alias} in den Truststore."
        keytool -importcert -noprompt -trustcacerts \
                -alias "${alias}" \
                -file "${cert}" \
                -cacerts -storepass changeit 2>/dev/null \
            || log "  (bereits vorhanden oder nicht importierbar - uebersprungen)"
    done
    [ "${found}" -eq 1 ] || true
}

# ---------------------------------------------------------------------------
# Initialisierung
# ---------------------------------------------------------------------------
run_init() {
    wait_for_db

    import_certificates

    if is_initialized; then
        log "IdentityIQ ist bereits initialisiert - Basisimport wird uebersprungen."
    else
        log "Erstinitialisierung: importiere init.xml und init-lcm.xml."
        log "(Das dauert einige Minuten - es werden mehrere tausend Objekte angelegt.)"
        iiq_console_checked "Basisimport init.xml / init-lcm.xml" <<'EOF'
import init.xml
import init-lcm.xml
EOF
        log "Basisimport abgeschlossen."

        # Patch NACH dem Basisimport - diese Reihenfolge ist zwingend.
        local patch_level=""
        if patch_level="$(detect_patch_level)"; then
            log "Wende Datenbank-Patch ${patch_level} an."
            "${IIQ_BIN}" patch "${patch_level}"
        else
            log "Kein Patch erkannt."
        fi

        # SERI und Accelerator Pack, falls im Paket enthalten.
        if [ -d "${SPHOME}/WEB-INF/config/seri" ]; then
            log "SERI erkannt - importiere init-seri.xml."
            echo "import seri/init-seri.xml" | iiq_console_checked "SERI-Import"
        fi
        if [ -f "${SPHOME}/WEB-INF/config/init-acceleratorpack.xml" ]; then
            log "Accelerator Pack erkannt - importiere init-acceleratorpack.xml."
            echo "import init-acceleratorpack.xml" | iiq_console_checked "Accelerator-Pack"
        fi
    fi

    # Eigene Objekte bei JEDEM Init-Lauf einspielen.
    # Das ist der Entwicklungs-Loop: XML in data/objects aendern,
    # "docker compose up iiq-init" - fertig, kein Rebuild noetig.
    import_folder /data/objects

    # Plugins installieren
    for plugin in /data/plugins/*.zip; do
        [ -e "${plugin}" ] || continue
        log "Installiere Plugin $(basename "${plugin}")."
        "${IIQ_BIN}" "plugin install ${plugin}" || \
            log "  (Installation fehlgeschlagen - ggf. bereits vorhanden)"
    done

    log "Initialisierung abgeschlossen."
}

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------
log "SPHOME=${SPHOME}"
log "Java: $(java -version 2>&1 | head -1)"

if [ "${INIT:-}" = "y" ]; then
    log "Betriebsart: INIT (einmalige Initialisierung)"
    run_init
    log "Init-Container beendet sich planmaessig."
    exit 0
fi

log "Betriebsart: Anwendungsserver"
wait_for_db
exec "$@"
