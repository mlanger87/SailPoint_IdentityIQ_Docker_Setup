# CLAUDE.md

Arbeitswissen zu diesem Repository. Enthält die technischen Fakten, die beim Aufbau
verifiziert wurden, und die Begründungen für die getroffenen Entscheidungen.

## Was dieses Repository ist

Eine lokale Docker-Entwicklungsumgebung für **SailPoint IdentityIQ 8.5** auf
**Tomcat 9 / OpenJDK 21 / PostgreSQL 17**.

Das Installationspaket ist lizenzpflichtig und liegt **nicht** im Repository. Es muss
manuell nach `installer/` gelegt werden.

## Verifizierte Fakten — nicht raten, hier nachsehen

Alle Angaben wurden direkt am Installationspaket geprüft. Die maßgebliche Quelle ist der
**mitgelieferte Installation Guide** (`doc/8.5_IdentityIQ_Installation_Guide.pdf` im ZIP) —
nicht Web-Recherche. Im Web ist die SailPoint-Dokumentation hinter Login.

### Plattform

| Thema | Fakt | Beleg |
|---|---|---|
| Java | **OpenJDK 21 und 17 unterstützt** | Guide S.3: „OpenJDK 21 and 17 is now supported on all environments" |
| App-Server | **Nur Tomcat 9.0** | Guide S.2, Abschnitt „Application Servers" |
| Datenbank | **PostgreSQL 17 und 16**, MySQL 8.4/8.0, MSSQL 2022/2019, Oracle 19c | Guide S.3 |
| MariaDB | **Nicht unterstützt** — taucht in der Liste nicht auf | Guide S.3 |
| Login | `spadmin` / `admin` | Guide S.17 |

### Warum Tomcat 9 zwingend ist

IIQ 8.5 ist **javax.servlet**-basiert, nicht jakarta:

- `WEB-INF/web.xml`: `<web-app version="2.5" xmlns="http://java.sun.com/xml/ns/javaee">`
- `javax.faces-2.2.20.jar`, Spring 5.3.39, Hibernate 5.5.9

Tomcat 10 und 11 verwenden den `jakarta.*`-Namensraum. Das WAR würde dort nicht starten.
**Ein Upgrade auf Tomcat 10/11 ist keine Option, solange IIQ javax nutzt.**

Tomcat 9.0.x wird bis 31.03.2027 gepflegt, danach folgt ein 9.1.x-Zweig bis 2030 — also
keine Sackgasse.

### Java 21: Bytecode und Modulschutz

Der Bytecode ist auf **Java 11** kompiliert (Major-Version 55) und läuft abwärtskompatibel
auf 21.

**Fallstrick:** Das Startskript `WEB-INF/bin/iiq` erkennt Java ≥ 17 selbst und ergänzt
`--add-opens`/`--add-exports`. **Tomcat erbt davon nichts.** Diese Flags müssen deshalb
separat in `CATALINA_OPTS` stehen (siehe `docker-compose.yml`). Laut Guide S.6 ist für
JDK 17+ mindestens erforderlich:

```
--add-exports=java.naming/com.sun.jndi.ldap=ALL-UNNAMED
```

### PostgreSQL — die drei Stolpersteine

**1. Der JDBC-Treiber fehlt.** Guide S.21: „The JDBC driver for PostgreSQL is not provided
with IdentityIQ." Im WAR liegt nur `mysql-connector-j-8.4.0.jar`. Der Treiber wird im
Dockerfile nachgeladen (`PG_JDBC_VERSION`, aktuell 42.7.5).

**2. Der Quartz-Delegate muss gesetzt werden.** Ohne ihn schlägt der Scheduler fehl:

```properties
scheduler.quartzProperties.org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.PostgreSQLDelegate
```

**3. Die DDL ist ein psql-Skript, kein reines SQL.** `create_identityiq_tables-8.5.postgresql`
(9.146 Zeilen) enthält 9 `\connect`-Meta-Kommandos und legt **selbst** an:

- 3 Datenbanken: `identityiq`, `identityiqah`, `identityiqPlugin`
- 3 Rollen mit Passwörtern (`CREATE USER ... ENCRYPTED PASSWORD`)

Daraus folgt:
- Sie muss von **psql** ausgeführt werden, nicht über einen JDBC-Treiber.
- `POSTGRES_DB` darf im Container **nicht** gesetzt werden, sonst kollidiert es.
- Die Passwörter werden beim Image-Build per `sed` durch die `.env`-Werte ersetzt.

Der Hibernate-Dialekt ist `sailpoint.persistence.PostgreSQL10Dialect` (die Klasse liegt im
`identityiq.jar`).

**Case-Insensitivity** wird über 244 Funktionsindizes auf `upper(...)` gelöst — es ist also
**keine** spezielle Collation nötig.

**Die Plugin-Datenbank hat absichtlich 0 Tabellen.** Sie enthält nur Schema und Rechte;
die Tabellen legt jedes Plugin bei seiner Installation selbst an. Das ist kein Fehler.

### Größenverhältnisse

| | |
|---|---|
| ZIP | 770 MB |
| `identityiq.war` | 742 MB |
| entpackt | ~1 GB in **8.984 Dateien** |
| davon `WEB-INF/lib-connectors` | 562 MB (15 Bundles) |

Deshalb: Multi-Stage-Build, `.dockerignore` mit Whitelist, und das WAR wird nach dem
Entpacken gelöscht.

## Architektur und Begründungen

### Warum ein eigener Init-Container

`iiq-init` läuft einmal durch und beendet sich; `iiq` startet erst danach
(`depends_on: condition: service_completed_successfully`).

Das trennt „einmalig initialisieren" sauber von „Server läuft" und bleibt korrekt, falls
später mehrere IIQ-Knoten laufen sollen — dann importiert nicht jeder Knoten parallel.

### Warum Idempotenz über die Datenbank statt über eine Markerdatei

`entrypoint.sh` prüft mit `get Identity spadmin` in der IIQ-Konsole, ob bereits
initialisiert wurde.

Referenzprojekt A nutzt stattdessen eine Markerdatei im Tomcat-Verzeichnis — das
funktioniert nur, weil dort das komplette Tomcat-Verzeichnis als Volume gemountet ist, was
wiederum dazu führt, dass ein Image-Rebuild wirkungslos bleibt. Der Datenbankzustand ist
die ehrlichere Quelle: er überlebt Rebuilds, Container-Neustarts und Volume-Wechsel.

### Warum Passwörter im Klartext (Vorgabe, bewusst)

`iiq encrypt` wird **nicht** standardmäßig verwendet. Grund: Verschlüsselte Werte sind an
den Keystore (`WEB-INF/classes/iiq.dat` + `iiq.cfg`) gebunden. Liegt der Keystore im Image,
ist damit nichts gewonnen — genau diesen Fehler macht Referenzprojekt D, das den Keystore
sogar ins Git-Repository eingecheckt hat und damit alle verschlüsselten Werte
entschlüsselbar macht.

Für diese lokale Dev-Umgebung sind Klartext-Passwörter aus `.env` ehrlicher und
nachvollziehbarer. Für produktionsnahe Setups wäre `iiq encrypt` mit einem **extern
gemounteten** Keystore der richtige Weg.

### Warum `ImportAction name='merge'` statt sed

Die Mail-Konfiguration (`data/objects/10-Configuration-Mail.xml`) ändert nur einzelne
Schlüssel der `SystemConfiguration`. Referenzprojekt A patcht stattdessen die `init.xml`
per `sed` — das ist destruktiv und überlebt kein Upgrade.

## Bekannte Fallstricke

### CRLF unter Windows

`.gitattributes` erzwingt `eol=lf` für alle Shell-Skripte. Ohne das schreibt Git unter
Windows CRLF, und der Container scheitert mit
`bad interpreter: No such file or directory`.

Betroffen sind auch Dateien **ohne** `.sh`-Endung. Referenzprojekt B sichert nur `*.sh` ab
und hat dadurch genau diese Lücke.

### `include_dir` lässt sich nicht per `-c` setzen

Beim Postgres-Tuning war der erste Ansatz
`CMD ["postgres", "-c", "include_dir=..."]`. Das scheitert mit
`FATAL: unrecognized configuration parameter "include_dir"` — der Parameter ist nur
innerhalb einer Konfigurationsdatei gültig. Gelöst über den initdb-Hook
`docker/postgres/00-apply-tuning.sh`, der das Tuning an die `postgresql.conf` anhängt.

### `iiq console` beendet sich nicht von allein

Ein `echo "befehl" | iiq console` **hängt**. Die Konsole wertet EOF auf stdin nicht als
Abbruch, sondern wartet weiter auf Eingaben — der Container läuft dann unbegrenzt weiter
(beim ersten Testlauf hier: 10 Minuten bei 43 % CPU, ohne jede Ausgabe).

Es muss immer ein explizites `quit` folgen. `entrypoint.sh` hängt es in `iiq_console()`
automatisch an.

### `iiq console` meldet Fehler nicht über den Exitcode

Ein fehlgeschlagenes Kommando liefert trotzdem **Exitcode 0**; der Stacktrace erscheint
nur auf stdout. Ohne Auswertung liefe ein misslungener Import unbemerkt durch und der
Server startete gegen eine halb-initialisierte Datenbank.

Deshalb gibt es `iiq_console_checked()`: Die Ausgabe wird eingesammelt und auf
`Exception|Caused by:|^Error:` geprüft. Referenzprojekt B hat weder `set -e` noch eine
solche Auswertung.

### Reihenfolge bei Patches

`import init.xml` muss **vor** `iiq patch` laufen. Umgekehrt schlägt der Patch fehl.

### Verwaiste Container blockieren den Namen

Nach abgebrochenen Läufen kann Docker Desktop einen Eintrag behalten, der weder über den
Namen noch über die ID entfernbar ist, den Namen aber weiterhin belegt. `docker compose up`
scheitert dann mit „Container name is already in use".

Erst `docker compose down --remove-orphans` (ohne `-v`!). Hilft das nicht oder antwortet
`docker ps` nicht mehr, hilft nur ein Neustart von Docker Desktop — Volumes und Images
überleben das.

## Die vier Referenzprojekte

Lagen unter `Other SailPoint IdentityIQ Docker Projekts als Reference/` (per `.gitignore`
ausgeschlossen). Analyse-Ergebnis in Kürze:

| Projekt | Stärke | Schwerster Mangel |
|---|---|---|
| **A** `docker-IdentityIQ` | Patch-/Versions-Handling, `iiq schema`-Fallback für Custom-WARs | Init läuft im gemounteten Volume → Rebuild wirkungslos; `apt-get install mariadb-server` zur Laufzeit |
| **B** `iiq-docker-developer-days-2025` | DDL im DB-Image, DB-basierte Idempotenz, `import_folder()`, `/data/objects`-Mount | Compose baut nichts, README ohne Build-Befehl |
| **C** `sailpoint-iiq-docker` | Init-Container-Pattern, Multi-DB, Demo-Daten, Traefik mit Sticky Sessions | Passwörter im Klartext ins Log (`cat iiq.properties`), Tomcat-Manager offen |
| **D** `standalone-docker-sailpoint-iiq` | SSB-Pipeline, `iiq encrypt`, non-root, Apache-Härtung | Java 8, MySQL 5.7, Keystore und privater Schlüssel im Repo, Init nur per `docker exec` |

Übernommen wurde: Architektur und Dev-Loop von **B**, Init-Container von **C**,
Sicherheitsmodell von **D**, Patch-Handling von **A**. Ergänzt wurden Healthchecks,
gepinnte Image-Tags und `set -euo pipefail` — das fehlt in allen vieren.

## Hinweise für die Arbeit an diesem Repo

- **Commits ohne Claude-Attribution.** Autor ist Michael Langer. Keine
  `Co-Authored-By`-Zeilen, kein „Generated with".
- **Sprache:** Deutsch, auch in Kommentaren. In den Shell-Skripten und Dockerfiles werden
  Umlaute als `ae/oe/ue` geschrieben, um Encoding-Probleme im Container zu vermeiden; in
  Markdown-Dateien werden echte Umlaute verwendet.
- **Nach Änderungen an `.env`-DB-Werten** ist ein Rebuild nötig, weil die Passwörter in die
  DDL und in `iiq.properties` eingebacken werden:
  ```
  docker compose build && docker compose down -v && docker compose up -d
  ```
- **Eigene IIQ-Objekte** gehören nach `data/objects/`. Ein Präfix steuert die
  Import-Reihenfolge (`10-`, `20-` …), weil `import_folder()` nach `sort` arbeitet.
