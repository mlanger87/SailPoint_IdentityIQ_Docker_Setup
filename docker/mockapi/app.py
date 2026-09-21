#!/usr/bin/env python3
# ===========================================================================
# Mock-REST-API als Zielsystem fuer den Web-Services-Connector
# ===========================================================================
# Bildet eine typische Personalverwaltungs-API nach, wie sie der
# WebServicesConnector anspricht:
#
#   GET    /api/v1/users            Liste mit Paging
#   GET    /api/v1/users/{id}       Einzelabruf
#   POST   /api/v1/users            anlegen
#   PATCH  /api/v1/users/{id}       aendern
#   DELETE /api/v1/users/{id}       loeschen
#   GET    /api/v1/groups           Gruppen (Entitlements)
#   GET    /api/v1/health           Verbindungstest
#
# Bewusst KEIN SCIM: Der SCIM-Connector hat sein eigenes Zielsystem
# (Container "scim"). Hier geht es um eine beliebige REST-Schnittstelle,
# wie sie in Projekten am haeufigsten vorkommt - mit eigener
# Datenstruktur, eigenem Paging und eigenem Fehlerformat.
#
# Die Antwortstruktur ist absichtlich verschachtelt (data[], meta{}), weil
# genau daran die Zuordnung im Connector haengt: rootPath muss darauf
# zeigen. Eine flache Liste wuerde diesen Teil nicht pruefen.
#
# Authentifizierung wahlweise ueber Bearer-Token (API_TOKEN) oder
# Basic Auth (BASIC_USER/BASIC_PASSWORD) - passend zu den beiden
# gaengigen Werten von authenticationMethod im Connector:
# "OAuthLogin" bzw. "BasicLogin".
#
# Die Daten stammen aus derselben HR-CSV wie die anderen Zielsysteme -
# die employeeNumber ist damit ueberall derselbe Korrelationsschluessel.
# ===========================================================================
import base64
import csv
import json
import os
import re
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

API_TOKEN = os.environ.get("API_TOKEN", "mocktoken")

# Basic Auth als Alternative zum Token. Der Web-Services-Connector
# beherrscht beides (authenticationMethod="BasicLogin" bzw.
# "OAuthLogin"); der Mock akzeptiert deshalb beide Varianten, damit
# sich die Anbindung umstellen laesst, ohne den Server anzufassen.
BASIC_USER = os.environ.get("BASIC_USER", "iiq")
BASIC_PASSWORD = os.environ.get("BASIC_PASSWORD", "iiqpassword")
PORT = int(os.environ.get("PORT", "8000"))
CSV_PFAD = Path(os.environ.get("HR_CSV", "/data/hr/HR-people.csv"))

# Wie viele Personen aus der CSV als Bestandskonten uebernommen werden.
# Wie bei LDAP und JDBC ist das Zielsystem fast leer - die uebrigen
# Konten legt IdentityIQ selbst an.
SEED_ANZAHL = int(os.environ.get("SEED_COUNT", "4"))

# Vorgabe fuer die Seitengroesse. Bewusst klein, damit das Paging im
# Connector auch bei wenigen Datensaetzen durchlaufen wird.
DEFAULT_SEITE = 50

_sperre = threading.Lock()
_benutzer: dict[str, dict] = {}
_gruppen: dict[str, dict] = {}


def jetzt() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def lade_startdaten() -> None:
    """
    Liest die Bestandskonten aus der HR-CSV.

    Faellt die Datei aus, startet der Dienst trotzdem - dann eben leer.
    Ein Mock, der wegen fehlender Testdaten gar nicht hochkommt, waere
    beim Debuggen hinderlich.
    """
    gruppen = [
        ("grp-portal-read",   "Portal: Lesezugriff"),
        ("grp-portal-write",  "Portal: Schreibzugriff"),
        ("grp-portal-admin",  "Portal: Administration"),
        ("grp-reports",       "Auswertungen"),
        ("grp-api-access",    "API-Zugriff"),
    ]
    for name, beschreibung in gruppen:
        gid = str(uuid.uuid5(uuid.NAMESPACE_DNS, name))
        _gruppen[gid] = {
            "id": gid,
            "name": name,
            "description": beschreibung,
            "createdAt": jetzt(),
        }

    if not CSV_PFAD.is_file():
        print(f"[mockapi] {CSV_PFAD} nicht gefunden - starte ohne Bestandskonten.")
        return

    try:
        with CSV_PFAD.open(encoding="utf-8") as f:
            zeilen = list(csv.DictReader(f, delimiter=";"))
    except (OSError, UnicodeDecodeError, csv.Error) as e:
        print(f"[mockapi] {CSV_PFAD} nicht lesbar ({e}) - "
              f"starte ohne Bestandskonten.")
        return

    # Nur aktive Personen als Bestandskonten, und nur die ersten paar.
    aktive = [z for z in zeilen if z.get("status") == "active"]
    uebersprungen = 0
    for i, z in enumerate(aktive[:SEED_ANZAHL]):
        # Fehlende oder leere Spalten duerfen den Start nicht verhindern.
        # Der Docstring verspricht, dass der Dienst auch ohne Testdaten
        # hochkommt - das muss auch fuer eine unvollstaendige Datei
        # gelten, nicht nur fuer eine fehlende.
        nummer = (z.get("employeeNumber") or "").strip()
        mail = (z.get("email") or "").strip()
        if not nummer:
            uebersprungen += 1
            continue
        uid = str(uuid.uuid5(uuid.NAMESPACE_DNS, nummer))
        # Die ersten beiden bekommen mehr Rechte - damit die
        # Entitlement-Aggregation etwas zu tun hat.
        zugeordnet = ["grp-portal-read"]
        if i == 0:
            zugeordnet += ["grp-portal-admin", "grp-api-access", "grp-reports"]
        elif i == 1:
            zugeordnet += ["grp-portal-write"]

        _benutzer[uid] = {
            "id": uid,
            "employeeId": nummer,
            "login": mail.split("@")[0] if "@" in mail else f"user{nummer}",
            "firstName": z.get("firstName", ""),
            "lastName": z.get("lastName", ""),
            "fullName": z.get("displayName", ""),
            "email": mail,
            "jobTitle": z.get("title", ""),
            "department": z.get("department", ""),
            "office": z.get("location", ""),
            "status": "ACTIVE",
            "roles": zugeordnet,
            "createdAt": jetzt(),
            "updatedAt": jetzt(),
        }

    hinweis = f", {uebersprungen} Zeile(n) uebersprungen" if uebersprungen else ""
    print(f"[mockapi] {len(_benutzer)} Bestandskonten, "
          f"{len(_gruppen)} Gruppen geladen{hinweis}.")


class Handler(BaseHTTPRequestHandler):

    # Die Standardausgabe des BaseHTTPRequestHandler geht auf stderr und
    # ist unstrukturiert - hier eine knappe Zeile je Anfrage.
    def log_message(self, format, *args):
        # BaseHTTPRequestHandler ruft log_message auch aus log_error
        # mit abweichender Signatur auf - args[1] gibt es dann nicht.
        status = args[1] if len(args) > 1 else "-"
        print(f"[mockapi] {self.command} {self.path} -> {status}")

    # -- Hilfsfunktionen --------------------------------------------------

    def _antwort(self, code: int, inhalt=None) -> None:
        daten = b"" if inhalt is None else json.dumps(inhalt).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(daten)))
        self.end_headers()
        if daten:
            self.wfile.write(daten)

    def _fehler(self, code: int, nachricht: str) -> None:
        # Eigenes Fehlerformat - Web-Service-APIs haben selten dasselbe.
        # Der Connector wertet den HTTP-Code aus, der Rumpf dient der
        # Fehlersuche.
        self._antwort(code, {
            "error": {"code": code, "message": nachricht,
                      "timestamp": jetzt()}
        })

    def _autorisiert(self) -> bool:
        """
        Akzeptiert Bearer-Token UND Basic Auth.

        So laesst sich die Applikation in IdentityIQ zwischen
        authenticationMethod="OAuthLogin" und "BasicLogin" umstellen,
        ohne den Mock neu zu konfigurieren.
        """
        kopf = self.headers.get("Authorization", "")

        if kopf == f"Bearer {API_TOKEN}":
            return True

        if kopf.startswith("Basic "):
            try:
                roh = base64.b64decode(kopf[6:]).decode("utf-8")
                benutzer, _, passwort = roh.partition(":")
                if benutzer == BASIC_USER and passwort == BASIC_PASSWORD:
                    return True
            except (ValueError, UnicodeDecodeError):
                pass

        self._fehler(401, "Ungueltige oder fehlende Anmeldedaten")
        return False

    def _rumpf(self) -> dict | None:
        laenge = int(self.headers.get("Content-Length") or 0)
        if laenge == 0:
            return {}
        try:
            return json.loads(self.rfile.read(laenge).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._fehler(400, "Rumpf ist kein gueltiges JSON")
            return None

    @staticmethod
    def _seite(elemente: list, query: dict) -> dict:
        """
        Baut eine Seite samt Metadaten.

        offset/limit statt page/size: Beide Varianten kommen vor, der
        Connector muss auf die jeweilige abgebildet werden. offset ist
        hier die haeufigere.
        """
        try:
            offset = max(0, int(query.get("offset", ["0"])[0]))
        except ValueError:
            offset = 0
        try:
            limit = int(query.get("limit", [str(DEFAULT_SEITE)])[0])
        except ValueError:
            limit = DEFAULT_SEITE
        limit = max(1, min(limit, 200))

        ausschnitt = elemente[offset:offset + limit]
        return {
            "data": ausschnitt,
            "meta": {
                "total": len(elemente),
                "offset": offset,
                "limit": limit,
                "hasMore": (offset + limit) < len(elemente),
            },
        }

    # -- Endpunkte --------------------------------------------------------

    def do_GET(self):
        zerlegt = urlparse(self.path)
        pfad = zerlegt.path.rstrip("/")
        query = parse_qs(zerlegt.query)

        # Der Verbindungstest laeuft bewusst ohne Token: So laesst sich
        # unterscheiden, ob der Dienst nicht erreichbar ist oder die
        # Anmeldung scheitert.
        if pfad == "/api/v1/health":
            self._antwort(200, {"status": "UP", "time": jetzt()})
            return

        if not self._autorisiert():
            return

        if pfad == "/api/v1/users":
            with _sperre:
                alle = sorted(_benutzer.values(), key=lambda b: b["employeeId"])
            self._antwort(200, self._seite(alle, query))
            return

        treffer = re.fullmatch(r"/api/v1/users/([^/]+)", pfad)
        if treffer:
            with _sperre:
                b = _benutzer.get(treffer.group(1))
            if b is None:
                self._fehler(404, "Benutzer nicht gefunden")
            else:
                self._antwort(200, b)
            return

        if pfad == "/api/v1/groups":
            with _sperre:
                alle = sorted(_gruppen.values(), key=lambda g: g["name"])
            self._antwort(200, self._seite(alle, query))
            return

        self._fehler(404, f"Unbekannter Pfad: {pfad}")

    def do_POST(self):
        if not self._autorisiert():
            return
        pfad = urlparse(self.path).path.rstrip("/")
        if pfad != "/api/v1/users":
            self._fehler(404, f"Unbekannter Pfad: {pfad}")
            return

        rumpf = self._rumpf()
        if rumpf is None:
            return

        for pflicht in ("login", "employeeId"):
            if not rumpf.get(pflicht):
                self._fehler(400, f"Pflichtfeld fehlt: {pflicht}")
                return

        with _sperre:
            # employeeId ist der fachliche Schluessel und muss eindeutig
            # bleiben - sonst korreliert IIQ spaeter mehrdeutig.
            for b in _benutzer.values():
                if b["employeeId"] == rumpf["employeeId"]:
                    self._fehler(409, "employeeId bereits vergeben")
                    return

            uid = str(uuid.uuid4())
            neu = {
                "id": uid,
                "employeeId": rumpf["employeeId"],
                "login": rumpf["login"],
                "firstName": rumpf.get("firstName", ""),
                "lastName": rumpf.get("lastName", ""),
                "fullName": rumpf.get("fullName", ""),
                "email": rumpf.get("email", ""),
                "jobTitle": rumpf.get("jobTitle", ""),
                "department": rumpf.get("department", ""),
                "office": rumpf.get("office", ""),
                "status": rumpf.get("status", "ACTIVE"),
                "roles": rumpf.get("roles", []),
                "createdAt": jetzt(),
                "updatedAt": jetzt(),
            }
            _benutzer[uid] = neu

        self._antwort(201, neu)

    def do_PATCH(self):
        if not self._autorisiert():
            return
        treffer = re.fullmatch(r"/api/v1/users/([^/]+)",
                               urlparse(self.path).path.rstrip("/"))
        if not treffer:
            self._fehler(404, "Unbekannter Pfad")
            return

        rumpf = self._rumpf()
        if rumpf is None:
            return

        with _sperre:
            b = _benutzer.get(treffer.group(1))
            if b is None:
                self._fehler(404, "Benutzer nicht gefunden")
                return
            for schluessel, wert in rumpf.items():
                # id und employeeId sind unveraenderlich: Ein Wechsel
                # wuerde die Korrelation in IIQ brechen.
                if schluessel in ("id", "employeeId", "createdAt"):
                    continue
                b[schluessel] = wert
            b["updatedAt"] = jetzt()
            ergebnis = dict(b)

        self._antwort(200, ergebnis)

    def do_DELETE(self):
        if not self._autorisiert():
            return
        treffer = re.fullmatch(r"/api/v1/users/([^/]+)",
                               urlparse(self.path).path.rstrip("/"))
        if not treffer:
            self._fehler(404, "Unbekannter Pfad")
            return

        with _sperre:
            if _benutzer.pop(treffer.group(1), None) is None:
                self._fehler(404, "Benutzer nicht gefunden")
                return

        self._antwort(204)


def main() -> None:
    lade_startdaten()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[mockapi] Lauscht auf Port {PORT}")
    print(f"[mockapi]   Bearer-Token: {API_TOKEN}")
    print(f"[mockapi]   Basic Auth:   {BASIC_USER} / {BASIC_PASSWORD}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
