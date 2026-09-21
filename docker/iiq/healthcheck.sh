#!/bin/bash
# ===========================================================================
# Healthcheck for the IdentityIQ container.
#
# Reference project C only checks "HEAD /identityiq" - that already
# reports "healthy" once Tomcat serves the context, while the application
# may still have no database connection at all.
#
# Here the login page is fetched. It is served with HTTP 200 only once
# the JSF application is fully up - which requires a working database
# connection.
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
        echo "Healthcheck failed: HTTP ${code} from ${URL}"
        exit 1
        ;;
esac
