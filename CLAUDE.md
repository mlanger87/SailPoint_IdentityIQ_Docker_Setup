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

**Die Tabellen liegen nicht in `public`.** Die DDL legt sie in ein gleichnamiges Schema
(`identityiq` bzw. `identityiqah`). Der PostgreSQL-Default für `search_path` ist aber
`"$user", public`.

Für IIQ selbst geht das gerade noch gut, weil sich `"$user"` zum Benutzernamen auflöst und
dieser zufällig genauso heißt wie das Schema. Für alle anderen Zugriffe — DBGate, `psql`
als `postgres`, eigene Auswertungen — ist das Schema dagegen nicht im Suchpfad:

```sql
SELECT * FROM spt_identity;             -- relation "spt_identity" does not exist
SELECT * FROM identityiq.spt_identity;  -- funktioniert
```

Deshalb setzt `docker/postgres/02-search-path.sql` den Suchpfad dauerhaft pro Rolle und
Datenbank (`ALTER ROLE ... IN DATABASE ... SET search_path`). Danach funktionieren
Abfragen ohne Schema-Präfix.

DBGate wählt das Schema von sich aus richtig und zeigt direkt alle 220 Tabellen.

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

### Warum die Testdaten generiert und nicht gepflegt werden

`scripts/generate-testdata.py` erzeugt aus **einer** Personenliste drei Dateien:
`data/hr/HR-people.csv`, `02-users.ldif` und `03-groups.ldif`. Sie sind **Artefakte** —
sie liegen im Git, weil die Container sie beim Start brauchen, aber geändert wird der
Generator.

Eine gemeinsame Quelle ist hier mehr als Bequemlichkeit: Die `employeeNumber` der
LDAP-Seed-Accounts **muss** zu einer Zeile der CSV passen, sonst korreliert nichts.
Zwei getrennt gepflegte Dateien wären nach der ersten Änderung auseinandergelaufen.

Drei der vier Referenzprojekte setzen phpLDAPadmin ein und legen Testdaten von Hand über
die Oberfläche an. Das skaliert nicht: Bei 100 Personen wäre weder die Verteilung
nachvollziehbar noch eine Änderung der Datenmenge praktikabel.

Ein fester Zufallsstartwert (`SEED`) macht die Erzeugung reproduzierbar — derselbe Aufruf
liefert dieselben Daten. Das ist nötig, damit ein neu aufgebautes Verzeichnis dieselben
Korrelationsergebnisse liefert wie vorher; sonst wären IIQ-Testläufe nicht vergleichbar.

Bei der Verteilung ging es um Brauchbarkeit, nicht um Größe:

- **Dreistufige Hierarchie** über `manager` (Department Head → Team Lead → Staff). Eine
  flache Liste hängt alle am selben Knoten, dann lässt sich keine Manager-Zertifizierung
  testen.
- **Ungleiche Gruppengrößen** (2 bis 55). Gleichverteilte Gruppen erzeugen bei der
  Rollenmodellierung nur Rauschen.
- **Abteilungsgebundene Gruppen** über `GROUP_DEPARTMENT_SCOPE` — Legal bekommt keinen
  Build-Server-Zugriff.
- **Privilegierte Gruppen** (`PRIVILEGED_GROUPS`) werden bevorzugt aus Führung und IT
  besetzt.

Ein Fallstrick beim Schreiben des Generators: Die Einschränkung auf privilegierte
Kandidaten muss **vor** der Berechnung der Zielgröße greifen. Andernfalls wird erst aus
allen Kandidaten eine Menge gezogen und danach auf die kleinere Gruppe reduziert — die
sensiblen Gruppen schrumpfen dann auf ein bis zwei Mitglieder und taugen nicht mehr als
Testdaten.

Werte mit Sonderzeichen müssen nach RFC 2849 base64-kodiert werden (`cn:: <base64>`).
`ldif_value()` erledigt das; ohne die Kodierung bricht der Import ab. Bei den jetzigen
englischen Daten greift das nicht mehr, die Funktion bleibt aber für eigene Ergänzungen.

Die LDIFs werden **nur bei leerem Datenverzeichnis** eingelesen
(`LDAP_CUSTOM_LDIF_DIR=/ldifs`). Nach einer Änderung muss deshalb das Volume weg:

```
docker compose rm -sf openldap && docker volume rm iiq85_ldapdata && docker compose up -d openldap
```

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

### `exec format error` bei Fremd-Images — `platform` setzen

Mit dem **containerd-Image-Store** (`Storage Driver: overlayfs`,
`io.containerd.snapshotter.v1`) wählt Docker bei Multi-Arch-Images nicht zuverlässig die
Host-Architektur, sondern offenbar den **ersten Eintrag im Manifest**. Steht dort
`linux/386` oder `linux/arm64` vor `linux/amd64`, startet der Container mit
`exec /<binary>: exec format error`.

Tückisch dabei: `docker image inspect` meldet trotzdem `Architecture: amd64` — die Angabe
stammt aus den Manifest-Metadaten, nicht aus den tatsächlichen Layern. Auch ein
`docker pull --platform linux/amd64` half nicht zuverlässig.

Betroffen waren `axllent/mailpit` (386 zuerst) und `dpage/pgadmin4` (arm64 zuerst).

Abhilfe: `platform: linux/amd64` im Service eintragen. Prüfen lässt sich die Reihenfolge
mit:

```bash
docker manifest inspect <image> | grep '"architecture"'
```

Bei pgAdmin half auch das nicht. Als Datenbank-Oberfläche wird deshalb **DBGate**
verwendet (`amd64` steht dort im Manifest an erster Stelle). Die drei Verbindungen werden
über `CONNECTIONS` und `LABEL_*`/`SERVER_*`/`USER_*`-Variablen vorkonfiguriert, es muss
also nichts manuell angelegt werden.

Zwischenzeitlich war Adminer im Einsatz — technisch einwandfrei, optisch aber sehr
altbacken.

Als LDAP-Browser dient **`dnknth/ldap-ui`** (Vue auf Alpine, `amd64` zuerst im Manifest).
phpLDAPadmin — in drei der vier Referenzprojekte im Einsatz — ist veraltet und das
`osixia`-Image seit Jahren ungepflegt. **LLDAP** wäre kein Browser, sondern ein eigener
LDAP-Server mit Weboberfläche und würde OpenLDAP ersetzen statt ergänzen.

Anmeldung erfolgt über `BIND_PATTERN=cn=%s,<BASE_DN>`, man gibt also nur `admin` ein statt
des vollständigen DN.

### IIQ-XML: Fallstricke beim Import

Die Objekte in `data/objects/` wurden gegen die **laufende 8.5-Instanz** verifiziert,
nicht aus Beispielen im Netz übernommen. Vier Dinge sind dabei aufgefallen:

**1. Die maßgebliche DTD wird zur Laufzeit erzeugt.** Sie liegt nirgends als Datei — die
Klasse `sailpoint.tools.xml.DTDBuilder` baut sie aus den Objektmodellen. Ausgeben lässt
sie sich in der Konsole:

```
dtd /tmp/sailpoint.dtd
```

Bei jeder Unsicherheit über ein Attribut ist das die Quelle, nicht die Erinnerung.

**2. `searchable` gibt es nicht.** In vielen Beispielen steht
`<ObjectAttribute searchable="true">`. Die 8.5-DTD kennt das Attribut nicht, der Import
scheitert mit *„Attribute searchable must be declared"*. Das Gegenstück heißt
**`extendedNumber`** (Spalten `extended1…extendedN`) oder **`namedColumn`** (eigene
benannte Spalte).

Das ist kein kosmetischer Unterschied: Ohne extendedNumber liegt der Wert nur im XML-Blob
und **kein Filter findet ihn** — Rollenzuweisung über `Selector` und der
`managerCorrelationFilter` laufen dann still ins Leere, ohne Fehlermeldung.

**3. `AttributeSource` nimmt kein `AttributeRef`.** Laut DTD:

```
<!ELEMENT AttributeSource ((ApplicationRef|RuleRef)*)>
```

Das Quellattribut gehört ins `name`-Attribut: `<AttributeSource name="employeeNumber">`.

**4. Der Task-Typ heißt `Identity`, nicht `IdentityRefresh`.** Die Fehlermeldung listet
dankenswerterweise alle gültigen Werte auf.

**Bonus — XML-Kommentare:** Doppelbindestriche sind in XML-Kommentaren verboten. Eine
Trennlinie aus `-----` bricht die Datei. Hier werden `=====` verwendet.

### `run` in der IIQ-Konsole braucht Anführungszeichen

```
run "LDAP Group Aggregation"      richtig
run LDAP Group Aggregation        falsch
```

Ohne Anführungszeichen trennt die Konsole am Leerzeichen und sucht eine Aufgabe namens
`LDAP` — Ergebnis: *„Ambiguous objects: LDAP Group Aggregation, LDAP Account
Aggregation"*. Tückisch, weil der Exitcode 0 bleibt und die Aufgabe einfach nicht läuft.

Hinzu kommt: `run` startet die Aufgabe über Quartz und kehrt sofort zurück. Beendet man
die Konsole gleich danach, fährt sie den Scheduler herunter und bricht die laufende
Aufgabe ab (*„The Scheduler has been shutdown"*). Für einen Lauf aus dem Skript muss die
Konsole offen bleiben, bis die Aufgabe fertig ist — in der Oberfläche unter
**Setup > Tasks** stellt sich die Frage nicht.

### `groupOfNames` verlangt mindestens ein `member`

Laut RFC 4519 ist eine mitgliederlose `groupOfNames` schema-widrig; slapd lehnt sie ab und
**bricht den gesamten LDIF-Import ab** — im Log steht nur „Loading custom LDIF files…",
kein Fehler. Symptom: 5 Accounts sind da, aber null Gruppen.

Da das Verzeichnis Zielsystem ist, sind viele Gruppen zunächst leer. Gelöst über den in
echten Verzeichnissen üblichen Platzhalter: `cn=placeholder,dc=example,dc=com` dient
leeren Gruppen als einziges `member`. Er liegt bewusst **außerhalb** von `ou=people` und
fällt damit nicht in den Suchbereich der Account-Aggregation.

Die Alternative `groupOfMembers` (wo `member` optional ist) steht im Bitnami-Image nicht
zur Verfügung — nur `groupOfNames` und `groupOfUniqueNames`.

### Gruppen-objectClass muss zum Schema passen

Ein Export aus einer anderen 8.5-Instanz nutzte `groupOfUniqueNames` mit
`groupMemberAttribute="uniqueMember"`. Unser Verzeichnis führt `groupOfNames` mit
`member`. Übernimmt man das ungeprüft, liefert die Gruppenaggregation **kein Ergebnis** —
ohne Fehler. Beide Werte müssen zusammenpassen.

### BeanShell: nicht gebundene Argumente sind `void`, nicht `null`

Der teuerste Fehler dieses Aufbaus. Die Regel `HR Set Inactive` prüfte anfangs
`if (link != null)`. Das schützt **nicht** — es löst den Fehler selbst aus, weil schon
das Auflösen der undefinierten Variablen scheitert:

```
bsh.EvalError: Attempt to resolve method: getAttribute() on undefined
variable or class name: link
```

Richtig ist die Prüfung auf `void`, mit Normalisierung auf eine lokale Variable:

```java
Link hrLink = null;
if (link != void && link != null) {
    hrLink = link;
}
```

Betroffen ist jedes Argument, das je nach Aufrufkontext fehlen kann — `link`, `result`,
`accountRequest`, `oldValue`. Dieselbe Regel läuft aus mehreren Kontexten: bei der
Aggregation ist `link` gebunden, beim Identity-Refresh ohne Account nicht.

**Die Folgekosten waren beträchtlich:** Der Fehler trat je Identität auf, die Aggregation
endete mit `Error`, und statt 102 Identitäten standen **185** in der Datenbank — jede
gescheiterte Zeile erzeugte eine zusätzliche. Aufräumen ließ sich das nur über
`sailpoint.api.Terminator`; ein direktes `DELETE FROM spt_identity` scheitert an
Fremdschlüsseln (`spt_identity_capabilities`).

### Signaturen an der laufenden Instanz prüfen, nicht aus dem Gedächtnis

Das JavaDoc listet für `Link` nur `toString()` — alle Getter sind geerbt und dort nicht
dokumentiert. Verlässlich ist eine Prüf-Rule mit Reflection:

```
import /tmp/SigCheck.xml
rule "ZZ Sig Check"
```

So verifiziert (IIQ 8.5):

| Aufruf | Befund |
|---|---|
| `Link.getAttribute(String)` | existiert, liefert `Object` |
| `Link.getStringAttribute(...)` | **existiert nicht** — nur `Identity` hat das |
| `Identity.getStringAttribute(String)` | existiert, kann `null` liefern |
| `Identity.isInactive()` | existiert |
| `ProvisioningResult.addError(String)` | existiert, daneben `(Message)` und `(Throwable)` |
| `STATUS_*` | `queued`, `committed`, `failed`, `retry` |
| `Schema.getAttributeDefinition(String)` | existiert |
| `JDBCConnector.buildMapFromResultSet(ResultSet, Schema)` | existiert |

**`source` in der Konsole taugt dafür nicht** — es liest die Datei zeilenweise als
Konsolenbefehle, nicht als BeanShell. Der Weg führt über eine temporäre Rule.

### IdentityTrigger: `Handler` ist kein Element

Ein Trigger referenziert seinen Workflow über das **Attribut** `handler` plus
`HandlerParameters` — nicht über ein `<Handler>`-Element. Die DTD erlaubt nur
`AssignedScope`, `Description`, `Owner`, `HandlerParameters`, `PendingWorkflow`,
`TriggerRule` und `Selector`.

```xml
<IdentityTrigger name="HR Leaver" attributeName="inactive"
                 oldValueFilter="false" newValueFilter="true"
                 type="AttributeChange"
                 handler="sailpoint.api.WorkflowTriggerHandler">
  <HandlerParameters>
    <Attributes>
      <Map><entry key="workflow" value="HR Leaver Workflow"/></Map>
    </Attributes>
  </HandlerParameters>
</IdentityTrigger>
```

Der Typ heißt `Rule` mit großem R; erlaubt sind `Create`, `Delete`, `AttributeChange`,
`Rule`, `ManagerTransfer`, `NativeChange`, `Alert`, `RapidSetup`.

Die Vorlage liefert die Instanz selbst: `get IdentityTrigger Leaver`.

**Für datumsgesteuerte Eintritte taugt `type="Create"` nicht** — der mitgelieferte Joiner
nutzt das, aber bei einem künftigen Eintrittsdatum entsteht die Identität lange vor dem
ersten Arbeitstag. Beide Trigger hier laufen deshalb über den Wechsel von `inactive`.

### Gruppenaggregation: `AccountGroupScan` gibt es nicht mehr

In 8.5 nutzt auch die Gruppenaggregation `sailpoint.task.ResourceIdentityScan`;
unterschieden wird über `<entry key="aggregationType" value="group"/>`. Die in älteren
Beispielen genannte Klasse `sailpoint.task.AccountGroupScan` führt zu `Error`, mit dem
Klassennamen als einziger Meldung.

### `AttributeSource` mit Regel braucht eine `ApplicationRef`

Das Attribut `inactive` sollte über die Regel `HR Set Inactive` aus den Datumsfeldern
berechnet werden. Zunächst als reine `RuleRef`:

```xml
<AttributeSource name="Rule: HR Set Inactive">
  <RuleRef><Reference class="sailpoint.object.Rule" name="HR Set Inactive"/></RuleRef>
</AttributeSource>
```

Ergebnis: **kein Fehler, kein Logeintrag — und keine Wirkung.** Der direkte Aufruf der
Regel lieferte nachweislich `true` für einen Ausgeschiedenen, aber `Identity.inactive`
blieb `false`. Die Regel wurde beim Refresh schlicht nie aufgerufen.

Richtig ist die anwendungsgebundene Form — dasselbe Muster zeigt ein Export aus einer
produktiven 8.5-Instanz (`AppRule: …`):

```xml
<AttributeSource name="AppRule: HR Set Inactive">
  <ApplicationRef>
    <Reference class="sailpoint.object.Application" name="HR-Application"/>
  </ApplicationRef>
  <RuleRef><Reference class="sailpoint.object.Rule" name="HR Set Inactive"/></RuleRef>
</AttributeSource>
```

Diese Klasse von Fehlern ist besonders unangenehm, weil nichts auffällt: kein Stacktrace,
keine Warnung, nur ein Attribut, das stillschweigend seinen Vorgabewert behält. Prüfen
lässt sich so etwas nur, indem man die Regel isoliert über `context.runRule(rule, args)`
aufruft und ihr Ergebnis mit dem tatsächlichen Attributwert vergleicht.

### Reihenfolge: durchsuchbare Attribute vor der ersten Aggregation

Der `managerCorrelationFilter` auf `employeeNumber` blieb zunächst wirkungslos — die
Hierarchie war leer, ohne jede Fehlermeldung. Der Filter selbst war korrekt; ein
isolierter Test mit `Filter.eq("employeeNumber", "1001")` fand die richtige Identität.

Die Ursache war die Reihenfolge: Beim ersten Aggregationslauf war `employeeNumber` noch
nicht als `extendedNumber` definiert, lag also nur im XML-Blob und war nicht filterbar.
Nach dem Import der ObjectConfig muss die Aggregation deshalb **erneut** laufen.

Merksatz: Erst `ObjectConfig`, dann Aggregation, dann Refresh. Ein nachträglich ergänztes
durchsuchbares Attribut erfordert einen weiteren Aggregationslauf.

### Stille Fehlkonfiguration — das wiederkehrende Muster

Vier Fehler dieses Aufbaus hatten dieselbe Signatur: **kein Fehler, kein Logeintrag, keine
Wirkung.** Das Objekt wird sauber importiert und gespeichert; ausgewertet wird es nicht.

| Fehlende Angabe | Folge |
|---|---|
| `AttributeSource` ohne `ApplicationRef` | Die Regel wird nie aufgerufen |
| `MatchTerm` ohne `type="IdentityAttribute"` | IIQ wertet ihn als Entitlement — der Selector greift nie |
| Attribut ohne `extendedNumber` | Der Wert liegt nur im XML-Blob, kein Filter findet ihn |
| `featuresString` ohne `MANAGER_LOOKUP` | Der `managerCorrelationFilter` wird ignoriert |

Der letzte Fall ist besonders tückisch: Der Filter steht korrekt in der Applikation, ein
`get Application` zeigt ihn an — nur ausgewertet wird er nicht. Die aus der Oberfläche
exportierten **DelimitedFile-Vorlagen führen `MANAGER_LOOKUP` nicht**, LDAP-Applikationen
dagegen schon.

**Konsequenz für die Fehlersuche:** Ein Blick in das gespeicherte Objekt genügt nicht — er
zeigt nur, dass der Wert *da* ist. Belastbar ist nur der Vergleich von erwartetem und
tatsächlichem Ergebnis:

```
// Regel isoliert aufrufen und mit dem Attributwert vergleichen
Object erwartet = context.runRule(rule, args);
boolean tatsaechlich = identity.isInactive();
```

So ließ sich zeigen, dass `HR Set Inactive` das richtige Ergebnis lieferte und trotzdem
nie zur Anwendung kam.

### `MatchTerm`: `null` ist nicht leer

Zur Abgrenzung des Leaver- vom Joiner-Fall sollte ein Selector prüfen, ob `endDate`
gesetzt ist:

```xml
<MatchTerm name="endDate" type="IdentityAttribute" negative="true" value=""/>
```

Das trifft auch auf künftige Eintritte zu, denn dort ist `endDate` **`null`**, nicht leer —
und `null` ist ungleich `""`. Gemessen: 10 Leaver-Läufe bei 4 echten Leavern.

Gelöst über eine `TriggerRule` mit `Util.isNotNullOrEmpty(...)` und `type="Rule"` am
Trigger. Letzteres bewusst: Ob IIQ bei `type="AttributeChange"` eine zusätzliche
`TriggerRule` überhaupt auswertet, ist nicht belegt — keiner der mitgelieferten Trigger
kombiniert beides.

**Zur Sache selbst:** Joiner und Leaver sind über `inactive` allein nicht unterscheidbar.
Beide wechseln von `false` auf `true`, denn wer erst nächsten Monat anfängt, ist heute
ebenso gesperrt wie jemand, der gegangen ist. Das Austrittsdatum trennt die Fälle.

### Web-Services-Connector: vier Stolpersteine

Die maßgebliche Referenz ist **`WEB-INF/config/connector/WebServices.xml`** im Paket — die
Formulardefinition, aus der die Oberfläche ihre Felder baut. Daraus:

```
authenticationMethod:  BasicLogin | OAuthLogin | OAuth2Login | No Auth
operationType:         Test Connection | Account Aggregation |
                       Account Delta Aggregation | Group Aggregation |
                       Get Object | Get Object-Group | Create Account |
                       Update Account | Delete Account |
                       Enable Account | Disable Account
```

**1. `entry` verträgt keinen CDATA-Inhalt.** Die DTD sagt
`<!ELEMENT entry ((key)?,(value)?)>` — der JSON-Rumpf gehört in ein
`<value><String><![CDATA[…]]></String></value>`.

**2. `responseCode` will `Integer`.** Mit `<String>200</String>` bricht der Connector mit
`class java.lang.String cannot be cast to class java.lang.Integer` ab.

**3. Der Name des Rumpf-Feldes hängt am `bodyFormat`:**

| `bodyFormat` | Feldname |
|---|---|
| `raw` | **`rawBody`** |
| `json` | `jsonBody` |

Der falsche Name lässt `WebServiceFacadeV2.initInternal` mit einer NullPointerException
abbrechen — die Konsole meldet nur **`null`**, ohne Hinweis auf die Ursache. Gefunden
durch Eingrenzen: eine minimale Applikation, die lief, dann schrittweise erweitert.

**4. `paginationSteps` ist ein URL-Fragment, kein Schlüsselwort.** In der
Formulardefinition ist es ein `textarea`. Der Wert `"offset"` wird nicht als Paging
erkannt; der Connector ruft denselben Endpunkt endlos auf — gemessen **11.943 Aufrufe**,
bis die Aufgabe von Hand beendet wurde. Bei kleinen Datenmengen Paging besser weglassen.

Bei Endlosschleifen: Die Aufgabe hängt auch nach einem `docker compose restart iiq` noch
als laufend in `spt_task_result`. Erst nach

```sql
UPDATE spt_task_result SET completion_status='Terminated' WHERE completion_status IS NULL;
```

lässt sie sich neu starten.

### SCIM 2.0: `authType` und der Klassenlader

**`authType="oauthBearer"`** für einen statischen Token — nicht `oauth2`, das entspricht
`OAuth2Login` und erwartet einen vollen Token-Fluss. Mit dem falschen Wert antwortet der
Server mit `401 invalidCredentials`. Die gültigen Werte:

```
javap -p -constants openconnector/connector/scim2/SCIM2Constants.class
  AUTH_TYPE_BASIC             = "Basic"
  AUTH_TYPE_BEARER            = "oauthBearer"
  AUTH_TYPE_OAUTH2            = "OAuth2Login"
  AUTH_TYPE_NO_AUTHENTICATION = "No Auth"
```

**`Class.forName` beweist bei Connector-Bundles nichts.** Ein Test auf
`openconnector.connector.scim2.SCIM2Connector` meldet `ClassNotFoundException`, obwohl die
Klasse in `connector-bundle-webservices.jar` liegt: Der `OpenConnectorAdapter` lädt sie
über einen eigenen Klassenlader. Aussagekräftig ist nur

```
connectorDebug "<Applikation>" test
```

### Compose-Override: Listen werden gemergt, Skalare ersetzt

Ein Unterschied mit Folgen. `docker-compose.override.yml` wird automatisch geladen und ist
damit der **Normalbetrieb**:

| Typ | Verhalten |
|---|---|
| `volumes:`, `ports:` (Listen) | werden **zusammengeführt** |
| `environment:`-Einträge (Skalare) | werden **ersetzt** |

Dadurch war `CATALINA_OPTS` im Override eine stille Kopie, die auseinanderlief:
`-Dcom.sun.jndi.ldap.connect.pool.protocol` stand nur in der Basis und war im Alltag
**nie aktiv**. Nachweisbar mit:

```
docker compose config | grep CATALINA_OPTS
```

Gelöst über `${IIQ_EXTRA_OPTS}`: Die Basis hängt die Variable an, der Override setzt nur
diesen Zusatz. Wichtig dabei — Compose expandiert `${...}` nur aus der `.env`, nicht aus
dem `environment`-Block eines anderen Dienstes.

### Das Fehlermuster im Entrypoint ist sicherheitskritisch

`iiq_console_checked()` bricht bei einem Treffer ab; wegen `set -e` endet der
Init-Container dann mit Fehler, und `iiq` startet wegen
`condition: service_completed_successfully` **gar nicht erst**. Ein falsch positiver
Treffer blockiert also den gesamten Stack.

Das ursprüngliche Muster enthielt `Unable to ` und das blanke `Exception` — beides kommt in
harmlosen Meldungen vor (`Unable to find localized message for key …`). Jetzt:

```
^Error:|^Caused by:|^[[:space:]]*at sailpoint\.|(java|javax|org|sailpoint|bsh)\.[A-Za-z.]*(Exception|Error)
```

Gegen die realen Meldungen dieser Sitzung geprüft: erkennt `RuntimeException`,
`SAXParseException`, `bsh.EvalError`, Stacktraces und `GeneralException`; lässt
`Unable to find…`, `ExceptionHandler` und normale Importausgaben durch.

**Wer das Muster ändert, testet es gegen beide Listen** — ein zu enges Muster lässt echte
Fehler durch, ein zu breites blockiert den Start.

### Generator: Mindestbesetzung je Abteilung

`max(MIN_PRO_ABTEILUNG, …)` hebt kleine Abteilungen an; in der Summe liegt das über dem
Sollwert, die Rundungsdifferenz wird **negativ**. Früher ging sie pauschal auf
`headcounts[0]` — dadurch wurde Sales als größte Abteilung negativ und in `build_people`
stillschweigend übersprungen:

```
--users   5  ->  14 Personen, Sales fehlt
--users  16  ->  16 Personen, Sales fehlt
--users  20  ->  20 Personen, vollständig
```

Jetzt wird der Fehlbetrag reihum abgezogen, ohne unter den Mindestwert zu gehen, und
`main()` lehnt zu kleine Werte mit einer Meldung ab statt still zu klemmen.

### Shell-Skripte: literale CR-Bytes machen die Datei für Git binär

`verify.sh` enthielt sieben literale CR-Bytes in `tr -d '<CR>'`. Folge:

```
$ git ls-files --eol scripts/verify.sh
i/-text w/-text attr/text eol=lf   scripts/verify.sh
```

`-text` heißt: Git behandelt die Datei als **binär**, und die `eol=lf`-Normalisierung aus
`.gitattributes` greift nicht mehr. Damit war ausgerechnet im Prüfskript die Lücke offen,
die oben unter „CRLF unter Windows" als Container-Killer beschrieben ist.

Statt eines literalen CR gehört dort `tr -d '[:space:]'` hin. Prüfen mit
`git ls-files --eol scripts/`: alle Shell-Skripte müssen `i/lf w/lf` zeigen.

### Ports an 127.0.0.1 binden

Docker veröffentlicht Ports ohne Präfix auf `0.0.0.0` — die Datenbank wäre dann im
gesamten Netz erreichbar, etwa im Kundennetz oder im Hotel-WLAN. Alle Bindungen tragen
deshalb `127.0.0.1:`; der Zugriff vom eigenen Rechner bleibt möglich.

### `data/` gehört nicht in den Build-Kontext

Kein Dockerfile kopiert daraus — alles läuft über Bind-Mounts. Stünde es in der Whitelist
von `.dockerignore`, würde jede Änderung an einer XML-Datei in `data/objects` den
Kontext-Hash ändern und Builds unnötig anstoßen.

### YAML-Faltblöcke kennen keine Kommentare

In `CATALINA_OPTS: >-` wird **jede** Zeile Teil des Wertes — auch eine, die mit `#`
beginnt. Sie landet als Argument bei der JVM, und Tomcat startet nicht mehr:

```
iiq  | Error: Could not find or load main class ssl
iiq  | <Java gibt seine vollständige Optionshilfe aus>
```

Erläuterungen gehören deshalb **vor** den Block, nicht hinein. Prüfen lässt sich der
tatsächliche Wert mit:

```
docker compose config | grep CATALINA_OPTS
```

**Werte mit Leerzeichen lassen sich im Faltblock gar nicht übergeben.** Beispiel
`-Dcom.sun.jndi.ldap.connect.pool.protocol=plain ssl`:

- ohne Anführungszeichen zerlegt die Shell die Option, `ssl` wird ein eigenes Argument
- mit Anführungszeichen landen diese als Literale im Wert

Beides verhindert den Start. Die Option ist deshalb nicht gesetzt; wer sie braucht, nutzt
`JAVA_TOOL_OPTIONS` im `environment`-Block, wo normale YAML-Quotierung gilt.

Der Fehler war vorher **latent**: Der Override überschrieb `CATALINA_OPTS` vollständig und
enthielt die Zeile nicht. Erst als die Duplizierung aufgelöst wurde, wurde die Option
wirksam — und brach den Start. Ein Beispiel dafür, dass das Beheben einer Inkonsistenz
einen verborgenen Fehler freilegen kann.

### Nach einem Umzug des Docker-Datenverzeichnisses

Ein Verschieben des Docker-Data-Root von `C:` nach `E:` hat Images und Volumes hier
vollständig erhalten — inklusive `iiq85_pgdata` mit dem initialisierten Schema. Der
Neuaufbau war nicht nötig.

Die angezeigte Image-Größe kann danach abweichen (`iiq-app` zeigte statt 1,73 GB plötzlich
4,24 GB), weil geteilte Basis-Layer neu gezählt werden. Das ist ein Anzeigeeffekt, kein
echter Mehrverbrauch.

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
