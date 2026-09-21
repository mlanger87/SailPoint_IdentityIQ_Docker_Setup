#!/bin/bash
# ===========================================================================
# Healthcheck fuer den IdentityIQ-Container.
#
# Referenzprojekt C prueft nur "HEAD /identityiq" - das meldet bereits
# "gesund", wenn Tomcat den Context ausliefert, die Anwendung aber noch
# gar keine Datenbankverbindung hat.
#
# Hier wird die Login-Seite abgerufen. Sie wird nur dann mit HTTP 200
# ausgeliefert, wenn die JSF-Anwendung vollstaendig hochgefahren ist -
# und das setzt eine funktionierende Datenbankverbindung voraus.
# ===========================================================================
set -uo pipefail

URL="http://localhost:8080/identityiq/login.jsf"

code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
             --max-time 8 "${URL}" 2>/dev/null || echo "000")"

case "${code}" in
    200|302)
        exit 0
        ;;
    *)
        echo "Healthcheck fehlgeschlagen: HTTP ${code} von ${URL}"
        exit 1
        ;;
esac
