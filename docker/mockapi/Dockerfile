# ===========================================================================
# Mock-REST-API als Zielsystem fuer den Web-Services-Connector
# ===========================================================================
# Bewusst ohne Framework: Die Standardbibliothek reicht fuer eine
# Mock-API vollkommen aus. Das spart eine Abhaengigkeitsverwaltung und
# haelt das Image bei rund 50 MB - ein Flask- oder FastAPI-Image waere
# ein Vielfaches davon, ohne hier etwas beizutragen.
#
# Die Daten kommen zur Laufzeit aus der HR-CSV (Bind-Mount), damit sie
# zu den anderen Zielsystemen passen.
# ===========================================================================
FROM python:3.13-alpine

# Nicht als root laufen lassen - dieselbe Ueberlegung wie beim
# IIQ-Container.
RUN adduser -D -u 1000 mockapi

WORKDIR /app
COPY --chown=1000:1000 docker/mockapi/app.py /app/app.py

USER 1000:1000

EXPOSE 8000

# Der Health-Endpunkt kommt ohne Token aus, damit der Healthcheck nicht
# am Token haengt.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; \
sys.exit(0 if urllib.request.urlopen('http://localhost:8000/api/v1/health', timeout=3).status==200 else 1)"

CMD ["python", "-u", "/app/app.py"]
