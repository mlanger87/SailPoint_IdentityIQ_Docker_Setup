# SailPoint IdentityIQ 8.5 — Docker-Entwicklungsumgebung

Eine lokale IdentityIQ-Umgebung, die mit einem Befehl startet.

**Stack:** IdentityIQ 8.5 · Tomcat 9 · OpenJDK 21 · PostgreSQL 17

---

## Voraussetzungen

- **Docker Desktop** (getestet mit 29.3.1), mindestens **8 GB RAM** für Docker
- Das **SailPoint-Installationspaket** — lizenzpflichtig, liegt nicht im Repository

---

## Erste Einrichtung

### 1. Installationspaket ablegen

Das Paket nach `installer/` kopieren:

```
installer/SailPoint_identityiq-8.5_Software_Package.zip
```

Es wird bewusst **nicht** eingecheckt (siehe `.gitignore`) — es enthält lizenzpflichtige
Software.

### 2. Setup ausführen

```powershell
.\scripts\setup.ps1
```

Das Skript prüft Docker, den verfügbaren Speicher und die Ports und legt die `.env` an.

### 3. Starten

```powershell
docker compose up -d
```

**Der erste Start dauert 15–25 Minuten.** In dieser Zeit passiert:

1. Die Images werden gebaut — das WAR entpackt sich auf ~1 GB in 8.984 Dateien
2. PostgreSQL legt die drei Datenbanken und rund 250 Tabellen an
3. Der Init-Container importiert die IdentityIQ-Basiskonfiguration

Fortschritt verfolgen:

```powershell
docker compose logs -f iiq-init
```

Spätere Starts dauern etwa eine Minute.

---

## Zugänge

| Dienst | Adresse | Anmeldung |
|---|---|---|
| **IdentityIQ** | http://localhost:8080/identityiq | `spadmin` / `admin` |
| **Mailpit** (Mailfang) | http://localhost:8025 | — |
| **Adminer** (Datenbank) | http://localhost:5050 | System `PostgreSQL`, Server `postgres`, `identityiq` / `identityiq` |
| PostgreSQL | `localhost:5432` | `identityiq` / `identityiq` |
| OpenLDAP | `localhost:1389` | `cn=admin,dc=example,dc=com` / `adminpassword` |

Die Ports lassen sich in der `.env` ändern.

---

## Alltag

Für die häufigsten Aufgaben gibt es ein Sammelskript:

```powershell
.\scripts\iiq.ps1 status      # Zustand aller Container
.\scripts\iiq.ps1 console     # IdentityIQ-Konsole
.\scripts\iiq.ps1 import      # eigene Objekte neu importieren
.\scripts\iiq.ps1 logs        # Logs von IdentityIQ folgen
.\scripts\iiq.ps1 psql        # SQL-Konsole auf der IIQ-Datenbank
.\scripts\iiq.ps1 shell       # Shell im IIQ-Container
.\scripts\iiq.ps1 restart     # IdentityIQ neu starten
.\scripts\iiq.ps1 reset       # alles zurücksetzen (mit Rückfrage)
```

### Eigene IIQ-Objekte einspielen

XML-Dateien nach `data/objects/` legen und einspielen:

```powershell
.\scripts\iiq.ps1 import
```

Die Dateien werden **alphabetisch** importiert — ein Zahlenpräfix steuert also die
Reihenfolge:

```
data/objects/
├── 10-Configuration-Mail.xml
├── 20-Application-LDAP.xml
└── 30-Rule-Correlation.xml
```

Alle Dateien werden in **einem** Konsolenaufruf importiert (über ein generiertes
`ImportAction`-Manifest). Das spart pro Datei rund 15 Sekunden JVM-Startzeit.

### Plugins installieren

ZIP-Dateien nach `data/plugins/` legen, dann `.\scripts\iiq.ps1 import`.

### Zertifikate hinterlegen

`.cer`-, `.crt`- oder `.pem`-Dateien nach `data/certs/` legen. Sie werden beim nächsten
Init in den Java-Truststore aufgenommen — nötig etwa für LDAPS gegen ein Testsystem mit
selbstsigniertem Zertifikat.

### Remote-Debugging

Der Debug-Port ist standardmäßig aktiv (über `docker-compose.override.yml`):

- **Host:** `localhost`, **Port:** `8000`
- In IntelliJ oder VS Code eine „Remote JVM Debug"-Konfiguration darauf anlegen

Tomcat wartet **nicht** auf den Debugger, startet also auch ohne IDE normal.

---

## Aufbau

```
├── docker-compose.yml            Hauptkonfiguration
├── docker-compose.override.yml   Entwicklung: Debug-Port, Log-Mount
├── .env                          Versionen, Ports, Passwörter (nicht im Git)
│
├── installer/                    → hier das SailPoint-ZIP ablegen
│
├── docker/
│   ├── iiq/                      IdentityIQ-Image
│   └── postgres/                 PostgreSQL mit IIQ-Schema
│
├── data/                         wird in die Container gemountet
│   ├── objects/                  eigene IIQ-XML-Objekte
│   ├── plugins/                  Plugin-ZIPs
│   └── certs/                    Zertifikate für den Truststore
│
└── scripts/                      Hilfsskripte
```

### Die Container

| Container | Aufgabe |
|---|---|
| `postgres` | PostgreSQL 17, legt beim ersten Start das IIQ-Schema an |
| `iiq-init` | läuft **einmal**, importiert die Basiskonfiguration, beendet sich |
| `iiq` | Tomcat 9 mit IdentityIQ, startet erst nach `iiq-init` |
| `mailpit` | fängt alle Mails ab |
| `openldap` | Testverzeichnis mit vier Benutzern und vier Gruppen |
| `adminer` | Weboberfläche für die Datenbank |

Die Trennung von `iiq-init` und `iiq` sorgt dafür, dass der Import genau einmal läuft.
Ein erneuter Init-Lauf erkennt am Datenbankzustand, dass bereits initialisiert wurde, und
spielt nur die eigenen Objekte neu ein.

---

## Problembehebung

### Der erste Start dauert sehr lange

Das ist normal. Das WAR ist 742 MB groß und entpackt sich auf ~1 GB in 8.984 Dateien;
anschließend werden mehrere tausend IIQ-Objekte in die Datenbank geschrieben.

Ob noch etwas passiert, zeigt:

```powershell
docker compose logs -f iiq-init
```

### `iiq` startet nicht

Zuerst prüfen, ob der Init sauber durchgelaufen ist:

```powershell
docker compose logs iiq-init
```

Der Init-Container muss sich mit Code 0 beenden. `iiq` startet sonst gar nicht erst.

### Adminer zeigt keine Tabellen

Zwei mögliche Ursachen:

**Auf der Übersichtsseite** („Select database") steht bei „Tables" und „Size" nur `?`.
Das ist normal — Adminer zählt diese Werte erst auf Klick („Compute").

**Nach dem Öffnen einer Datenbank** ist die Liste leer: Die IIQ-Tabellen liegen nicht im
Standard-Schema `public`, sondern in einem gleichnamigen Schema `identityiq`. Oben in der
Schema-Auswahl von `public` auf `identityiq` umstellen — oder direkt aufrufen:

```
http://localhost:5050/?pgsql=postgres&username=postgres&db=identityiq&ns=identityiq
```

Für Abfragen ist das nicht nötig: Der `search_path` ist so gesetzt, dass
`SELECT * FROM spt_identity` auch ohne Präfix funktioniert.

### Port bereits belegt

Die betreffende Zeile in der `.env` ändern, zum Beispiel:

```
IIQ_HTTP_PORT=8081
```

Danach `docker compose up -d`.

### Passwörter geändert — was nun?

Die Datenbankpasswörter werden beim Image-Build in die DDL und in `iiq.properties`
eingebacken. Nach einer Änderung in der `.env`:

```powershell
docker compose build
docker compose down -v
docker compose up -d
```

`down -v` löscht die Datenbank. Das ist hier nötig, weil die Benutzer beim ersten Start
angelegt wurden.

### „Container name is already in use" — obwohl der Container nicht existiert

Nach abgebrochenen Läufen kann in Docker Desktop ein verwaister Eintrag zurückbleiben.
Typisches Bild: `docker compose up` meldet einen Namenskonflikt, aber weder
`docker rm <name>` noch `docker rm <id>` finden den Container.

Reihenfolge zum Auflösen:

```powershell
docker compose down --remove-orphans      # ohne -v, damit die Datenbank bleibt
```

Hilft das nicht — oder antwortet `docker ps` gar nicht mehr —, hängt der Daemon.
Dann hilft nur ein Neustart von Docker Desktop. **Volumes und Images bleiben dabei
erhalten**, die initialisierte Datenbank geht also nicht verloren.

### Komplett von vorn beginnen

```powershell
.\scripts\iiq.ps1 reset
docker compose up -d
```

---

## Hinweise zur Sicherheit

Diese Umgebung ist für die **lokale Entwicklung** gedacht:

- Die Passwörter stehen im Klartext in `.env` und `iiq.properties`
- Es gibt kein TLS; alles läuft über HTTP
- Die Debug-Seiten von IdentityIQ sind aktiv

Für produktionsnahe Umgebungen wären mindestens nötig: `iiq encrypt` mit einem extern
eingebundenen Keystore, TLS-Terminierung, und Passwörter aus einem Secret-Store statt aus
einer Datei.

Technische Hintergründe und die Begründungen der Architekturentscheidungen stehen in
[CLAUDE.md](CLAUDE.md).
