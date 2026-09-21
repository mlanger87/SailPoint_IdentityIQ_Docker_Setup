#!/bin/bash
# ===========================================================================
# Legt ein IdentityIQ-Patch-JAR ueber die entpackte Webapp.
#
# Aufruf: apply-patch.sh <SPHOME> <IIQ_VERSION> <IIQ_PATCH>
#
# Das Patch-JAR ersetzt Dateien im entpackten WAR (unzip -o). Die
# Datenbankseite des Patches ("iiq patch <version><patch>" sowie die
# upgrade_identityiq_tables-*.postgresql) wird NICHT hier ausgefuehrt,
# sondern spaeter im Init-Container - dort ist die Datenbank verfuegbar.
#
# Reihenfolge ist wichtig (dokumentiert in Referenzprojekt A):
# "import init.xml" muss VOR "iiq patch" laufen.
# ===========================================================================
set -euo pipefail

SPHOME="${1:?SPHOME fehlt}"
IIQ_VERSION="${2:?IIQ_VERSION fehlt}"
IIQ_PATCH="${3:-}"

if [ -z "${IIQ_PATCH}" ]; then
    echo "[patch] Kein Patch-Level gesetzt (IIQ_PATCH leer) - uebersprungen."
    exit 0
fi

INSTALLER_DIR="${INSTALLER_DIR:-/build/installer}"
PATCH_JAR="${INSTALLER_DIR}/identityiq-${IIQ_VERSION}${IIQ_PATCH}.jar"

if [ ! -f "${PATCH_JAR}" ]; then
    echo "[patch] FEHLER: IIQ_PATCH='${IIQ_PATCH}' gesetzt, aber" >&2
    echo "        ${PATCH_JAR} wurde nicht gefunden." >&2
    echo "        Vorhandene Dateien in ${INSTALLER_DIR}:" >&2
    ls -1 "${INSTALLER_DIR}" 2>/dev/null | sed 's/^/          /' >&2 || true
    echo "        Entweder das Patch-JAR nach installer/ legen" >&2
    echo "        oder IIQ_PATCH in der .env leeren." >&2
    exit 1
fi

echo "[patch] Wende ${PATCH_JAR##*/} auf ${SPHOME} an."
cd "${SPHOME}"
unzip -q -o "${PATCH_JAR}"

# Der Patch bringt eine README mit, aus der spaeter das Patch-Level
# automatisch erkannt werden kann (Muster aus Referenzprojekt B).
if ls "${SPHOME}"/WEB-INF/config/patch/identityiq-*-README.txt >/dev/null 2>&1; then
    echo "[patch] Patch-README gefunden:"
    ls -1 "${SPHOME}"/WEB-INF/config/patch/identityiq-*-README.txt | sed 's/^/    /'
fi

echo "[patch] Dateien eingespielt. Die Datenbank-Migration erfolgt beim Init."
