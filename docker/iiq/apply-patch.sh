#!/bin/bash
# ===========================================================================
# Lays an IdentityIQ patch JAR over the unpacked webapp.
#
# Usage: apply-patch.sh <SPHOME> <IIQ_VERSION> <IIQ_PATCH>
#
# The patch JAR replaces files in the unpacked WAR (unzip -o). The
# database side of the patch ("iiq patch <version><patch>" and the
# upgrade_identityiq_tables-*.postgresql) is NOT run here but later in
# the init container - the database is available there.
#
# Order matters (documented in reference project A):
# "import init.xml" must run BEFORE "iiq patch".
# ===========================================================================
set -euo pipefail

SPHOME="${1:?SPHOME missing}"
IIQ_VERSION="${2:?IIQ_VERSION missing}"
IIQ_PATCH="${3:-}"

if [ -z "${IIQ_PATCH}" ]; then
    echo "[patch] No patch level set (IIQ_PATCH empty) - skipped."
    exit 0
fi

INSTALLER_DIR="${INSTALLER_DIR:-/build/installer}"
PATCH_JAR="${INSTALLER_DIR}/identityiq-${IIQ_VERSION}${IIQ_PATCH}.jar"

if [ ! -f "${PATCH_JAR}" ]; then
    echo "[patch] ERROR: IIQ_PATCH='${IIQ_PATCH}' is set, but" >&2
    echo "        ${PATCH_JAR} was not found." >&2
    echo "        Files present in ${INSTALLER_DIR}:" >&2
    ls -1 "${INSTALLER_DIR}" 2>/dev/null | sed 's/^/          /' >&2 || true
    echo "        Either place the patch JAR in installer/" >&2
    echo "        or clear IIQ_PATCH in .env." >&2
    exit 1
fi

echo "[patch] Applying ${PATCH_JAR##*/} to ${SPHOME}."
cd "${SPHOME}"
unzip -q -o "${PATCH_JAR}"

# The patch ships a README from which the patch level is detected
# automatically later (pattern from reference project B).
if ls "${SPHOME}"/WEB-INF/config/patch/identityiq-*-README.txt >/dev/null 2>&1; then
    echo "[patch] Patch README found:"
    ls -1 "${SPHOME}"/WEB-INF/config/patch/identityiq-*-README.txt | sed 's/^/    /'
fi

echo "[patch] Files applied. Database migration happens during init."
