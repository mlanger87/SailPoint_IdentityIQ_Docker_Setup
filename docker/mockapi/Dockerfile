# ===========================================================================
# Mock REST API as target system for the Web Services connector
# ===========================================================================
# Deliberately no framework: the standard library is entirely sufficient
# for a mock API. Saves dependency management and keeps the image at
# ~50 MB - a Flask or FastAPI image would be several times that without
# contributing anything here.
#
# Data comes at runtime from the HR CSV (bind mount) so it matches the
# other target systems.
# ===========================================================================
FROM python:3.13-alpine

# Do not run as root - same reasoning as for the IIQ container.
RUN adduser -D -u 1000 mockapi

WORKDIR /app
COPY --chown=1000:1000 docker/mockapi/app.py /app/app.py

USER 1000:1000

EXPOSE 8000

# The health endpoint needs no token, so the healthcheck does not depend
# on it.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; \
sys.exit(0 if urllib.request.urlopen('http://localhost:8000/api/v1/health', timeout=3).status==200 else 1)"

CMD ["python", "-u", "/app/app.py"]
