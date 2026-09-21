# Sitzungsstand — Fortsetzung nach Neustart

**Stand:** 21.09.2026 · Commit `42e1b84` auf `main`

Diese Datei hält fest, wo wir stehen, damit nach einem PC-Neustart direkt
weitergearbeitet werden kann.

---

## Wo wir gerade stehen

Das Docker-Konstrukt ist **fertig gebaut und funktioniert**. Der vollständige
Durchlauf — Datenbank anlegen, IdentityIQ initialisieren — ist einmal
erfolgreich durchgelaufen.

Offen war zuletzt nur noch der Start des Gesamtstacks und die abschließende
Funktionsprüfung.

### Unterbrechungsgrund

Docker Desktop sollte von `C:` auf `E:` umgezogen werden, weil die
Systemplatte voll läuft. Der Umzug hat nicht funktioniert.

---

## Nächste Schritte nach dem Neustart

### 1. Prüfen, was den Neustart überlebt hat

```powershell
docker images | Select-String "iiq-"
docker volume ls | Select-String "iiq85"
```

**Fall A — Images und Volume sind noch da:**

```powershell
cd E:\002_GIT_REPOS_NEU\SailPoint_IdentityIQ_Docker_Setup
docker compose up -d
```

**Fall B — Images oder Volume fehlen** (etwa weil der Umzug doch etwas
verschoben hat):

```powershell
cd E:\002_GIT_REPOS_NEU\SailPoint_IdentityIQ_Docker_Setup
docker compose build          # 15-25 Minuten
docker compose up -d          # Init läuft automatisch mit
```

Das ist unkritisch: Solange das Installationspaket in `installer/` liegt,
lässt sich alles vollständig neu erzeugen.

### 2. Funktionsprüfung

```bash
bash scripts/verify.sh
```

Prüft Container, Datenbanken, Basiskonfiguration, Weboberfläche,
Quartz-Scheduler und Mailpit.

### 3. Danach noch offen

- Anmeldung in der Oberfläche testen (`spadmin` / `admin`)
- Mailversand über Mailpit prüfen
- Entwicklungs-Loop prüfen: XML in `data/objects` ablegen → `.\scripts\iiq.ps1 import`

---

## Zum Docker-Umzug auf E:

Der Weg führt über **Settings → Resources → Advanced → „Disk image location"**.

Wenn das nicht greift, sind das die üblichen Ursachen:

1. **Docker Desktop läuft noch.** Die Umstellung braucht einen vollständigen
   Neustart der Anwendung, nicht nur ein Schließen des Fensters.
2. **Die WSL-VM hängt.** Dann hilft vor dem Umzug:
   ```powershell
   wsl --shutdown
   ```
   (Siehe unten — genau dieser Fall ist in dieser Sitzung schon einmal
   aufgetreten.)
3. **Zu wenig Platz am Ziel.** Für Images und Volumes sollten mindestens
   20 GB frei sein.

Alternative, falls der Umzug weiter scheitert: Speicher freigeben statt
verschieben.

```powershell
docker builder prune -a      # Build-Cache, oft mehrere GB
docker image prune -a        # ungenutzte Images
```

Achtung: `docker system prune -a --volumes` würde auch `iiq85_pgdata`
löschen — dann ist die initialisierte Datenbank weg und der Init läuft
beim nächsten Start neu.

---

## Was bereits fertig ist

| Bereich | Stand |
|---|---|
| PostgreSQL-Image | fertig, geprüft — 3 Datenbanken, 220 + 32 Tabellen |
| IIQ-Image | fertig, geprüft — 1,73 GB, PG-Treiber, non-root |
| `docker-compose.yml` | 6 Dienste, Healthchecks, Abhängigkeiten |
| Init-Container | **erfolgreich durchgelaufen**, Exitcode 0 |
| Dokumentation | `README.md`, `CLAUDE.md` |
| Skripte | `setup.ps1`/`.sh`, `iiq.ps1`, `verify.sh` |
| Git | Commit `42e1b84`, 30 Dateien |

### Vier behobene Fehler

Alle vier sind in den Referenzprojekten ebenfalls vorhanden oder ungelöst:

1. **`iiq console` hängt ohne `quit`** — EOF auf stdin beendet die Konsole
   nicht. Der erste Testlauf blockierte dadurch 10 Minuten bei 43 % CPU.
2. **`iiq console` liefert bei Fehlern Exitcode 0** — ein fehlgeschlagener
   Import wäre unbemerkt durchgelaufen. Die Ausgabe wird jetzt ausgewertet.
3. **`include_dir` ist bei PostgreSQL nicht per `-c` setzbar** — das Tuning
   läuft über einen initdb-Hook.
4. **Healthcheck lief im Init-Container**, wo es gar kein Tomcat gibt →
   dauerhaft „unhealthy".

### Eine Änderung am Schluss

`bitnami/openldap:2.6` existiert nicht mehr (Bitnami hat 2025 nach
`bitnamilegacy` verschoben). In `docker-compose.yml` steht jetzt
`bitnamilegacy/openldap:2.6.10-debian-12-r4`. Diese Änderung ist **noch
nicht committet** und noch nicht erprobt.

---

## Gelernt in dieser Sitzung

**Docker-Prozesse nie hart beenden.** Ein `Stop-Process -Force` auf Docker
Desktop hinterlässt eine halb-tote WSL-VM. Docker Desktop wartet dann
endlos auf die Engine — sichtbar als „Starting the Docker Engine…" bei
0 % CPU.

Auflösung:

```powershell
wsl --shutdown
```

Danach Docker Desktop normal starten. **Volumes und Images überleben das.**

---

## Technischer Kern in drei Sätzen

IIQ 8.5 ist `javax.servlet`-basiert, deshalb ist **Tomcat 9 zwingend** —
Tomcat 10/11 würden das WAR nicht starten. **OpenJDK 21 ist offiziell
unterstützt**, die `--add-opens`-Flags müssen aber in `CATALINA_OPTS`
stehen, weil Tomcat sie nicht vom `iiq`-Startskript erbt. **PostgreSQL 17**
ist die richtige Wahl — eigener Dialekt und eigene DDL von SailPoint —,
wobei der JDBC-Treiber nachgeladen werden muss und der
Quartz-`PostgreSQLDelegate` zwingend zu setzen ist.

Ausführlich in [CLAUDE.md](CLAUDE.md).
