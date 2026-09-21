#!/usr/bin/env python3
# ===========================================================================
# Generator fuer die Testdaten der Entwicklungsumgebung
# ---------------------------------------------------------------------------
# Erzeugt aus EINER Personenliste zwei Ausgaben:
#
#   data/hr/HR-people.csv            autoritative Quelle (alle Personen)
#   docker/openldap/ldif/02-users.ldif   nur die Seed-Accounts im Zielsystem
#   docker/openldap/ldif/03-groups.ldif  alle Gruppen (Entitlements)
#
# Die Rollenverteilung der Systeme:
#   - Die HR-CSV ist die QUELLE. Sie erzeugt in IIQ die Identitaeten.
#   - LDAP ist das ZIELSYSTEM. Dort legt IIQ Accounts an; es ist deshalb
#     bis auf wenige Seed-Accounts leer.
#
# Warum ueberhaupt Seed-Accounts und nicht ein komplett leeres LDAP:
# Damit sich der Korrelationsfall testen laesst - ein bereits bestehender
# Account trifft auf eine neu erzeugte Identitaet. Bei einem leeren
# Verzeichnis gaebe es nur den Provisionierungsfall.
#
# Die Gruppen bleiben dagegen VOLLSTAENDIG im Verzeichnis: sie sind die
# Entitlements, die IIQ zuweisen koennen soll. Ein Zielsystem ohne
# Gruppen kann nichts Interessantes provisionieren.
#
# Die Daten sind englisch gehalten, wie in realen Projekten ueblich.
#
# Warum ein Generator statt handgepflegter Dateien:
#   - Beide Ausgaben stammen aus derselben Personenliste und koennen
#     deshalb gar nicht auseinanderlaufen. Die employeeNumber der
#     Seed-Accounts passt garantiert zu einer Zeile in der CSV.
#   - Die Datenmenge laesst sich aendern, ohne hunderte Zeilen zu pflegen.
#   - Ein fester Zufallsstartwert macht den Lauf reproduzierbar: gleicher
#     Aufruf, gleiche Daten. Das ist wichtig, damit ein neu erzeugtes
#     Verzeichnis dieselben Korrelationsergebnisse liefert wie vorher.
#
# Aufruf:
#     python scripts/generate-testdata.py
#     python scripts/generate-testdata.py --users 250 --seed-accounts 10
#
# Die CSV wird vom IIQ-Container gelesen und ist per Bind-Mount sofort
# wirksam - eine Aenderung braucht nur einen neuen Aggregationslauf.
#
# Die LDIFs werden dagegen nur bei LEEREM Datenverzeichnis eingelesen:
#     docker compose rm -sf openldap
#     docker volume rm iiq85_ldapdata
#     docker compose up -d openldap
# ===========================================================================
import argparse
import base64
import csv
import datetime
import random
import unicodedata
from pathlib import Path

BASE_DN = "dc=example,dc=com"
PEOPLE_DN = f"ou=people,{BASE_DN}"

# Die objectClass groupOfNames verlangt laut RFC 4519 mindestens ein
# member - eine leere Gruppe ist schema-widrig und wird von slapd
# abgelehnt. Da das Verzeichnis Zielsystem ist, sind aber viele
# Gruppen zunaechst leer und warten auf Provisionierung.
#
# Loesung ist der in echten Verzeichnissen uebliche Platzhalter: ein
# eigener Eintrag, der leeren Gruppen als einziges member dient.
# In IIQ wird er ueber den Aggregationsfilter ausgeblendet.
PLACEHOLDER_DN = f"cn=placeholder,{BASE_DN}"
GROUPS_DN = f"ou=groups,{BASE_DN}"
PASSWORD = "password"

# Mehrfach verwendet - als Konstante, damit ein Umbenennen an einer
# Stelle genuegt.
DEPT_HR = "Human Resources"

# Fester Startwert: gleicher Aufruf erzeugt exakt dieselben Daten.
SEED = 20250921

# Stichtag fuer die Datumsberechnung. Bewusst NICHT date.today(): sonst
# aendert sich die Datei bei jedem Lauf und die Reproduzierbarkeit waere
# dahin. Die Datumswerte werden relativ zu diesem Tag erzeugt.
STICHTAG = datetime.date(2026, 9, 21)

# Verteilung der Lebenszyklus-Faelle. Die Zahlen sind Prozentwerte und
# so gewaehlt, dass sich jeder Fall testen laesst, ohne dass die
# Ausnahmen die Normalfaelle erdruecken.
ANTEIL_ZUKUENFTIGER_EINTRITT = 5     # Joiner: Eintritt liegt vor uns
ANTEIL_BEFRISTET_AKTIV = 10          # Enddatum gesetzt, noch nicht erreicht
ANTEIL_AUSGESCHIEDEN = 8             # Leaver: Enddatum ist ueberschritten

FIRST_NAMES = [
    "Alice", "Brian", "Claire", "Daniel", "Emma", "Frank", "Grace",
    "Henry", "Irene", "James", "Karen", "Lucas", "Maria", "Nathan",
    "Olivia", "Peter", "Quinn", "Rachel", "Steven", "Tina", "Ulrich",
    "Victoria", "Walter", "Xenia", "Yasmin", "Zachary", "Andrew", "Beatrice",
    "Charles", "Diana", "Edward", "Fiona", "George", "Helen", "Isaac",
    "Julia", "Kevin", "Laura", "Michael", "Nadine", "Oliver", "Patricia",
    "Robert", "Sandra", "Thomas", "Ursula", "Vincent", "Wendy",
]

LAST_NAMES = [
    "Adams", "Baker", "Bennett", "Brooks", "Campbell", "Carter", "Clark",
    "Collins", "Cooper", "Davis", "Edwards", "Evans", "Fisher", "Foster",
    "Gibson", "Graham", "Hall", "Harris", "Hayes", "Hughes", "Jenkins",
    "Johnson", "Kelly", "Lewis", "Marshall", "Mitchell", "Morgan", "Murphy",
    "Nelson", "Parker", "Phillips", "Reed", "Richardson", "Roberts",
    "Robinson", "Russell", "Sanders", "Scott", "Simmons", "Stewart",
    "Sullivan", "Taylor", "Thompson", "Turner", "Walker", "Ward",
    "Watson", "Wright", "Young",
]

# Abteilung -> (Standort, Kostenstelle, Gewicht). Die Verteilung ist
# bewusst ungleich: Sales und IT sind gross, Legal und Procurement klein -
# das entspricht eher einer echten Organisation als eine Gleichverteilung.
DEPARTMENTS = [
    ("Sales",        "London",    "CC-1000", 22),
    ("IT",           "London",    "CC-2000", 20),
    ("Operations",   "Manchester", "CC-3000", 18),
    ("Finance",      "London",    "CC-4000", 12),
    (DEPT_HR,        "Bristol",   "CC-5000", 10),
    ("Marketing",    "London",    "CC-6000",  8),
    ("Procurement",  "Manchester", "CC-7000",  6),
    ("Legal",        "London",    "CC-8000",  4),
]

TITLES_DEPARTMENT_HEAD = ["Department Head", "Director"]
TITLES_TEAM_LEAD = ["Team Lead", "Manager"]
TITLES_STAFF = [
    "Associate", "Specialist", "Consultant", "Analyst",
    "Coordinator", "Administrator", "Officer",
]
TITLES_IT = [
    "Software Engineer", "System Administrator", "Database Administrator",
    "Security Engineer", "Solution Architect", "QA Engineer",
]

# Anwendungsbezogene Gruppen (Entitlements). Der Zahlenwert ist das
# relative Gewicht in Prozent - je hoeher, desto mehr Mitglieder.
APPLICATION_GROUPS = [
    ("app-crm-read",           "CRM: read access",                     35),
    ("app-crm-write",          "CRM: write access",                    18),
    ("app-crm-admin",          "CRM: administration",                  12),
    ("app-erp-read",           "ERP: read access",                     30),
    ("app-erp-post",           "ERP: post transactions",               25),
    ("app-erp-admin",          "ERP: administration",                  12),
    ("app-dms-read",           "Document management: read access",     40),
    ("app-dms-write",          "Document management: write access",    20),
    ("app-timesheet",          "Time tracking",                        45),
    ("app-expenses",           "Expense reporting",                    25),
    ("app-personnel-files",    "Personnel files (sensitive)",          30),
    ("app-payroll-data",       "Payroll data (sensitive)",             20),
    ("app-contract-archive",   "Contract archive (sensitive)",         30),
    ("app-wiki-read",          "Wiki: read access",                    50),
    ("app-wiki-write",         "Wiki: write access",                   28),
    ("app-ticketing",          "Ticketing system: agent",              22),
    ("app-ticketing-admin",    "Ticketing system: administration",     15),
    ("app-monitoring",         "Monitoring console",                   25),
    ("app-build-server",       "Build server",                         30),
    ("app-source-control",     "Source control",                       40),
    ("app-test-environment",   "Test environment",                     35),
    ("app-production-access",  "Production system (critical)",         15),
    ("app-database-read",      "Database: read access",                30),
    ("app-database-admin",     "Database: administration",             12),
    ("app-vpn",                "VPN access",                           38),
    ("app-wifi-guest",         "Guest WiFi",                           30),
    ("app-colour-printing",    "Colour printing",                      26),
    ("app-licence-office",     "Office licence",                       55),
    ("app-licence-cad",        "CAD licence",                          20),
    ("app-licence-bi",         "BI tooling",                           11),
    ("app-training-portal",    "Training portal",                      33),
    ("app-ordering",           "Ordering system",                      35),
    ("app-warehouse",          "Warehouse management",                 25),
    ("app-quality",            "Quality management",                   20),
    ("app-archive",            "Long-term archive",                    13),
    ("app-video-conferencing", "Video conferencing licence",           42),
    ("app-customer-portal",    "Customer portal: support",             16),
    ("app-digital-signature",  "Digital signature",                    22),
    ("app-fleet",              "Fleet management",                     18),
]

# Gruppen, die fachlich nur zu bestimmten Abteilungen passen. Damit wird
# vermieden, dass etwa Legal Zugriff auf den Build-Server bekommt -
# unrealistisch und fuer die Rollenmodellierung wertlos.
GROUP_DEPARTMENT_SCOPE = {
    "app-source-control":     {"IT"},
    "app-build-server":       {"IT"},
    "app-monitoring":         {"IT"},
    "app-database-read":      {"IT"},
    "app-database-admin":     {"IT"},
    "app-test-environment":   {"IT", "Operations"},
    "app-production-access":  {"IT"},
    "app-ticketing-admin":    {"IT"},
    "app-personnel-files":    {DEPT_HR},
    "app-payroll-data":       {DEPT_HR, "Finance"},
    "app-contract-archive":   {"Legal", "Procurement"},
    "app-erp-post":           {"Finance", "Procurement", "Operations"},
    "app-licence-cad":        {"Operations"},
    "app-warehouse":          {"Operations", "Procurement"},
    "app-quality":            {"Operations"},
    "app-ordering":           {"Procurement", "Operations"},
    "app-crm-write":          {"Sales", "Marketing"},
    "app-crm-admin":          {"Sales", "IT"},
    "app-customer-portal":    {"Sales", "Marketing"},
    "app-digital-signature":  {"Legal", "Finance", "Procurement"},
    "app-fleet":              {"Sales", "Operations"},
}

# Gruppen, deren Mitglieder bevorzugt aus Fuehrung oder IT stammen.
# Rein zufaellig gezogene Administratoren waeren unrealistisch und
# wuerden die Rollenmodellierung verfaelschen.
PRIVILEGED_GROUPS = {
    "app-crm-admin", "app-erp-admin", "app-ticketing-admin",
    "app-database-admin", "app-production-access",
    "app-personnel-files", "app-payroll-data", "app-contract-archive",
}


def ascii_lower(text: str) -> str:
    """Wandelt Sonderzeichen in ASCII um - uid und mail duerfen keine enthalten."""
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(c for c in decomposed if not unicodedata.combining(c)).lower()


def ldif_value(attribute: str, value: str) -> str:
    """
    Gibt eine LDIF-Zeile aus. Werte mit Sonderzeichen muessen nach
    RFC 2849 base64-kodiert werden (erkennbar am doppelten Doppelpunkt),
    sonst bricht der Import ab.
    """
    if value.isascii():
        return f"{attribute}: {value}"
    encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
    return f"{attribute}:: {encoded}"


def lebenszyklus(rnd: random.Random) -> tuple[str, str, str]:
    """
    Wuerfelt Eintritts- und Austrittsdatum sowie den daraus folgenden
    Status.

    Der Status wird hier BERECHNET und nicht frei gewuerfelt - sonst
    gaebe es Zeilen, die sich widersprechen (etwa "active" bei einem
    Austritt in der Vergangenheit). Genau solche Widersprueche machen
    Testdaten fuer Lifecycle-Prozesse unbrauchbar.

    Rueckgabe: (startDate, endDate, status) im Format JJJJ-MM-TT.
    endDate ist leer, wenn unbefristet.
    """
    wurf = rnd.randint(1, 100)

    # Fall 1: Eintritt liegt in der Zukunft (Joiner).
    if wurf <= ANTEIL_ZUKUENFTIGER_EINTRITT:
        start = STICHTAG + datetime.timedelta(days=rnd.randint(3, 45))
        return start.isoformat(), "", "future"

    # Fall 2: bereits ausgeschieden (Leaver).
    if wurf <= ANTEIL_ZUKUENFTIGER_EINTRITT + ANTEIL_AUSGESCHIEDEN:
        start = STICHTAG - datetime.timedelta(days=rnd.randint(400, 3000))
        ende = STICHTAG - datetime.timedelta(days=rnd.randint(1, 180))
        return start.isoformat(), ende.isoformat(), "inactive"

    # Fall 3: befristet, aber noch aktiv - das Enddatum liegt vor uns.
    if wurf <= (ANTEIL_ZUKUENFTIGER_EINTRITT + ANTEIL_AUSGESCHIEDEN
                + ANTEIL_BEFRISTET_AKTIV):
        start = STICHTAG - datetime.timedelta(days=rnd.randint(30, 900))
        ende = STICHTAG + datetime.timedelta(days=rnd.randint(5, 120))
        return start.isoformat(), ende.isoformat(), "active"

    # Fall 4: der Normalfall - unbefristet beschaeftigt.
    start = STICHTAG - datetime.timedelta(days=rnd.randint(60, 5000))
    return start.isoformat(), "", "active"


def build_people(count: int, rnd: random.Random) -> list[dict]:
    """
    Verteilt die Personen gemaess den Gewichten auf die Abteilungen und
    baut eine dreistufige Hierarchie auf:
        Department Head -> Team Lead -> Staff
    Erst dadurch wird eine Manager-Zertifizierung in IIQ sinnvoll
    testbar; bei einer flachen Liste haengen alle am selben Knoten.
    """
    weights = [d[3] for d in DEPARTMENTS]
    total = sum(weights)
    headcounts = [max(2, round(count * w / total)) for w in weights]

    # Rundungsdifferenz auf die groesste Abteilung legen.
    headcounts[0] += count - sum(headcounts)

    used_uids: set[str] = set()
    people: list[dict] = []
    next_number = 1001

    for (department, location, cost_centre, _), headcount in zip(DEPARTMENTS, headcounts):
        if headcount <= 0:
            continue

        department_people: list[dict] = []
        for position in range(headcount):
            first = rnd.choice(FIRST_NAMES)
            last = rnd.choice(LAST_NAMES)

            base_uid = f"{ascii_lower(first)[0]}{ascii_lower(last)}"
            uid = base_uid
            suffix = 2
            while uid in used_uids:
                uid = f"{base_uid}{suffix}"
                suffix += 1
            used_uids.add(uid)

            # Position 0 fuehrt die Abteilung, 1 und 2 sind Team Leads.
            if position == 0:
                title = rnd.choice(TITLES_DEPARTMENT_HEAD)
                level = "department-head"
            elif position <= 2 and headcount > 6:
                title = rnd.choice(TITLES_TEAM_LEAD)
                level = "team-lead"
            else:
                pool = TITLES_IT if department == "IT" else TITLES_STAFF
                title = rnd.choice(pool)
                level = "staff"

            person = {
                "uid": uid,
                "first": first,
                "last": last,
                "cn": f"{first} {last}",
                "mail": f"{ascii_lower(first)}.{ascii_lower(last)}@example.com",
                "employeeNumber": str(next_number),
                "title": title,
                "department": department,
                "location": location,
                "costCentre": cost_centre,
                "level": level,
                "phone": f"+44 20 {rnd.randint(2000, 9999)} {rnd.randint(1000, 9999)}",
                "manager": None,
            }

            # Eintritt, Austritt und der daraus folgende Status.
            start, ende, status = lebenszyklus(rnd)
            person["startDate"] = start
            person["endDate"] = ende
            person["status"] = status
            next_number += 1
            department_people.append(person)

        # Fuehrungskraefte bleiben aktiv und unbefristet.
        #
        # Waere eine Abteilungsleitung ausgeschieden, zeigte der
        # manager-Verweis ihrer Mitarbeitenden auf eine inaktive
        # Identitaet - die Manager-Zertifizierung liefe dann ins Leere.
        # Der Leaver-Fall bleibt ueber die Mitarbeitenden trotzdem
        # testbar.
        for person in department_people:
            if person["level"] != "staff":
                person["endDate"] = ""
                # status nur dann auf active setzen, wenn der Eintritt
                # nicht noch bevorsteht - sonst entstuende der
                # Widerspruch "active" bei kuenftigem startDate.
                if person["status"] == "inactive":
                    person["status"] = "active"

        # Hierarchie innerhalb der Abteilung verdrahten.
        head = department_people[0]
        team_leads = [p for p in department_people if p["level"] == "team-lead"]
        for person in department_people[1:]:
            if person["level"] == "team-lead" or not team_leads:
                person["manager"] = head["uid"]
            else:
                person["manager"] = rnd.choice(team_leads)["uid"]

        people.extend(department_people)

    return people


def build_groups(people: list[dict], count: int, rnd: random.Random) -> list[dict]:
    """
    Baut vier Arten von Gruppen:
      1. je eine Abteilungsgruppe (vollstaendige Mitgliedschaft)
      2. je eine Standortgruppe
      3. organisatorische Sammelgruppen
      4. Anwendungsgruppen mit gewichteter, teils abteilungsgebundener
         Mitgliedschaft
    """
    groups: list[dict] = []

    # 1. Abteilungsgruppen
    for department, _, _, _ in DEPARTMENTS:
        members = [p["uid"] for p in people if p["department"] == department]
        if members:
            slug = department.lower().replace(" ", "-")
            groups.append({
                "cn": f"dept-{slug}",
                "description": f"Department: {department}",
                "members": members,
            })

    # 2. Standortgruppen
    for location in sorted({d[1] for d in DEPARTMENTS}):
        members = [p["uid"] for p in people if p["location"] == location]
        if members:
            groups.append({
                "cn": f"site-{location.lower()}",
                "description": f"Site: {location}",
                "members": members,
            })

    # 3. Organisatorische Sammelgruppen
    groups.append({
        "cn": "org-managers",
        "description": "All managers and department heads",
        "members": [p["uid"] for p in people
                    if p["level"] in ("department-head", "team-lead")],
    })
    groups.append({
        "cn": "org-all-staff",
        "description": "All employees",
        "members": [p["uid"] for p in people],
    })

    # 4. Anwendungsgruppen bis zur Zielanzahl
    remaining = count - len(groups)
    for cn, description, weight in APPLICATION_GROUPS[:max(0, remaining)]:
        scope = GROUP_DEPARTMENT_SCOPE.get(cn)
        candidates = [p for p in people
                      if scope is None or p["department"] in scope]
        if not candidates:
            continue

        # Privilegierte Gruppen bevorzugt aus Fuehrung und IT besetzen.
        # Der Kandidatenkreis wird eingeschraenkt, BEVOR die Zielgroesse
        # berechnet wird - sonst schrumpfen diese Gruppen auf ein oder
        # zwei Mitglieder zusammen und taugen nicht mehr als Testdaten.
        if cn in PRIVILEGED_GROUPS:
            privileged = [p for p in candidates
                          if p["level"] != "staff" or p["department"] == "IT"]
            if len(privileged) >= 3:
                candidates = privileged

        target = max(2, round(len(candidates) * weight / 100))
        members = [p["uid"] for p in rnd.sample(candidates,
                                                min(target, len(candidates)))]

        groups.append({
            "cn": cn,
            "description": description,
            "members": sorted(members),
        })

    return groups[:count]


def write_users(path: Path, people: list[dict]) -> None:
    """
    Schreibt NUR die Seed-Accounts. LDAP ist das Zielsystem - die
    uebrigen Accounts legt IIQ per Provisionierung selbst an.
    """
    password_b64 = base64.b64encode(PASSWORD.encode()).decode()
    lines: list[str] = [
        "# ===========================================================================",
        "# Seed-Accounts im Zielsystem",
        "# ---------------------------------------------------------------------------",
        "# ERZEUGT von scripts/generate-testdata.py - Aenderungen hier gehen beim",
        "# naechsten Lauf verloren. Stattdessen den Generator anpassen.",
        "#",
        f"# Anzahl: {len(people)}",
        f'# Passwort aller Konten: "{PASSWORD}"',
        "#",
        "# LDAP ist hier das ZIELSYSTEM, nicht die Quelle. Es enthaelt",
        "# deshalb absichtlich nur wenige Accounts: alle uebrigen legt",
        "# IdentityIQ aus der HR-CSV heraus per Provisionierung an.",
        "#",
        "# Diese wenigen Accounts gibt es, damit sich der Korrelationsfall",
        "# testen laesst - bestehender Account trifft auf neue Identitaet.",
        "# Ihre employeeNumber kommt aus derselben Personenliste wie die",
        "# CSV, die Korrelation greift also garantiert.",
        "# ===========================================================================",
        "",
    ]

    for person in people:
        lines.extend([
            f"dn: uid={person['uid']},{PEOPLE_DN}",
            "objectClass: inetOrgPerson",
            "objectClass: organizationalPerson",
            "objectClass: person",
            "objectClass: top",
            f"uid: {person['uid']}",
            ldif_value("cn", person["cn"]),
            ldif_value("sn", person["last"]),
            ldif_value("givenName", person["first"]),
            f"mail: {person['mail']}",
            f"employeeNumber: {person['employeeNumber']}",
            ldif_value("title", person["title"]),
            f"departmentNumber: {person['department']}",
            f"ou: {person['department']}",
            f"l: {person['location']}",
            f"employeeType: {person['level']}",
            f"telephoneNumber: {person['phone']}",
            f"description: Cost centre {person['costCentre']}",
        ])
        if person["manager"]:
            lines.append(f"manager: uid={person['manager']},{PEOPLE_DN}")
        lines.append(f"userPassword:: {password_b64}")
        lines.append("")

    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def write_groups(path: Path, groups: list[dict]) -> None:
    total = sum(len(g["members"]) for g in groups)
    lines: list[str] = [
        "# ===========================================================================",
        "# Testgruppen",
        "# ---------------------------------------------------------------------------",
        "# ERZEUGT von scripts/generate-testdata.py - Aenderungen hier gehen beim",
        "# naechsten Lauf verloren. Stattdessen den Generator anpassen.",
        "#",
        f"# Anzahl Gruppen: {len(groups)}",
        f"# Mitgliedschaften gesamt: {total}",
        "#",
        "# Aufbau:",
        "#   dept-*   Abteilungen (vollstaendige Mitgliedschaft)",
        "#   site-*   Standorte",
        "#   org-*    organisatorische Sammelgruppen",
        "#   app-*    Anwendungsberechtigungen (Entitlements)",
        "#",
        "# objectClass groupOfNames - das Attribut member enthaelt volle DNs.",
        "#",
        "# Die Gruppen sind vollstaendig vorhanden, auch wenn im Verzeichnis",
        "# nur wenige Accounts liegen: sie sind die Entitlements, die IIQ",
        "# zuweisen koennen soll. member verweist nur auf die Seed-Accounts,",
        "# da ein DN auf einen nicht existierenden Eintrag zeigen wuerde.",
        "#",
        "# Gruppen ohne Seed-Mitglied erhalten cn=placeholder als member:",
        "# groupOfNames verlangt mindestens eines (RFC 4519). Der Eintrag",
        "# wird in 01-structure.ldif angelegt und in IIQ herausgefiltert.",
        "# ===========================================================================",
        "",
    ]

    for group in groups:
        lines.extend([
            f"dn: cn={group['cn']},{GROUPS_DN}",
            "objectClass: groupOfNames",
            "objectClass: top",
            f"cn: {group['cn']}",
            ldif_value("description", group["description"]),
        ])
        if group["members"]:
            for uid in group["members"]:
                lines.append(f"member: uid={uid},{PEOPLE_DN}")
        else:
            # Ohne dieses member wuerde slapd den Eintrag ablehnen.
            lines.append(f"member: {PLACEHOLDER_DN}")
        lines.append("")

    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def write_hr_csv(path: Path, people: list[dict]) -> None:
    """
    Schreibt die autoritative HR-Quelle.

    Trennzeichen ist das Semikolon, passend zur Application-Definition
    (entry key="delimiter" value=";"). Ein Semikolon ist hier robuster
    als ein Komma, weil Freitextfelder wie der Titel sonst haeufiger
    escaped werden muessten.

    Die Manager-Spalte enthaelt die employeeNumber des Vorgesetzten,
    nicht dessen Namen - IIQ loest die Hierarchie ueber den
    managerCorrelationFilter auf diesen Schluessel auf.

    startDate und endDate steuern den Lebenszyklus:
        startDate in der Zukunft  -> Eintritt steht bevor (Joiner)
        endDate leer              -> unbefristet
        endDate in der Zukunft    -> befristet, noch aktiv
        endDate in der Vergangenheit -> ausgeschieden (Leaver)

    Die Spalte status ist daraus ABGELEITET und wird nicht unabhaengig
    gewuerfelt - sonst entstuenden widerspruechliche Zeilen wie "active"
    bei laengst ueberschrittenem Austrittsdatum.
    """
    spalten = [
        "employeeNumber", "firstName", "lastName", "displayName", "email",
        "title", "department", "location", "costCentre", "employeeType",
        "phone", "managerEmployeeNumber", "startDate", "endDate", "status",
    ]

    nach_uid = {p["uid"]: p for p in people}

    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter=";", quoting=csv.QUOTE_MINIMAL,
                            lineterminator="\n")
        writer.writerow(spalten)
        for person in people:
            manager = nach_uid.get(person["manager"]) if person["manager"] else None
            writer.writerow([
                person["employeeNumber"],
                person["first"],
                person["last"],
                person["cn"],
                person["mail"],
                person["title"],
                person["department"],
                person["location"],
                person["costCentre"],
                person["level"],
                person["phone"],
                manager["employeeNumber"] if manager else "",
                person["startDate"],
                person["endDate"],
                person["status"],
            ])


def pick_seed_accounts(people: list[dict], count: int,
                       rnd: random.Random) -> list[dict]:
    """
    Waehlt die Personen aus, die bereits einen LDAP-Account haben.

    Die Auswahl ist nicht rein zufaellig: Es sollen verschiedene
    Abteilungen und Hierarchieebenen vertreten sein, damit die
    Korrelation nicht nur an einem einzigen Muster geprueft wird.
    """
    if count >= len(people):
        return list(people)

    ausgewaehlt: list[dict] = []
    gesehen: set[str] = set()

    # Zuerst je eine Person aus moeglichst vielen Abteilungen.
    nach_abteilung: dict[str, list[dict]] = {}
    for person in people:
        nach_abteilung.setdefault(person["department"], []).append(person)

    for abteilung in sorted(nach_abteilung):
        if len(ausgewaehlt) >= count:
            break
        kandidat = rnd.choice(nach_abteilung[abteilung])
        ausgewaehlt.append(kandidat)
        gesehen.add(kandidat["uid"])

    # Rest zufaellig auffuellen.
    rest = [p for p in people if p["uid"] not in gesehen]
    fehlend = count - len(ausgewaehlt)
    if fehlend > 0 and rest:
        ausgewaehlt.extend(rnd.sample(rest, min(fehlend, len(rest))))

    return sorted(ausgewaehlt, key=lambda p: p["employeeNumber"])


def limit_groups_to_seeds(groups: list[dict],
                          seed_uids: set[str]) -> list[dict]:
    """
    Entfernt aus den Gruppen alle Mitglieder, die keinen Account im
    Verzeichnis haben.

    Notwendig, weil member einen echten DN erwartet. Ein Verweis auf
    einen nicht existierenden Eintrag ist zwar in OpenLDAP mit der
    Standardkonfiguration erlaubt, waere aber bei der Aggregation
    irrefuehrend: IIQ meldete Entitlements fuer Accounts, die es nicht
    gibt.

    Die Gruppe selbst bleibt bestehen, auch wenn sie dadurch leer wird -
    sie ist ein Entitlement, das IIQ zuweisen koennen soll.
    """
    begrenzt: list[dict] = []
    for group in groups:
        begrenzt.append({
            **group,
            "members": [uid for uid in group["members"] if uid in seed_uids],
        })
    return begrenzt


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Erzeugt die Testdaten: HR-CSV (Quelle) und LDAP-LDIFs (Ziel).")
    parser.add_argument("--users", type=int, default=100,
                        help="Anzahl der Personen in der HR-CSV (Vorgabe: 100)")
    parser.add_argument("--groups", type=int, default=50,
                        help="Anzahl der LDAP-Gruppen (Vorgabe: 50)")
    parser.add_argument("--seed-accounts", type=int, default=5,
                        help="Personen, die bereits einen LDAP-Account haben "
                             "(Vorgabe: 5)")
    parser.add_argument("--seed", type=int, default=SEED,
                        help="Zufallsstartwert fuer reproduzierbare Laeufe")
    args = parser.parse_args()

    rnd = random.Random(args.seed)
    repo = Path(__file__).resolve().parent.parent
    ldif_dir = repo / "docker" / "openldap" / "ldif"
    hr_dir = repo / "data" / "hr"
    hr_dir.mkdir(parents=True, exist_ok=True)

    people = build_people(args.users, rnd)
    groups = build_groups(people, args.groups, rnd)

    seed_people = pick_seed_accounts(people, args.seed_accounts, rnd)
    seed_uids = {p["uid"] for p in seed_people}
    seed_groups = limit_groups_to_seeds(groups, seed_uids)

    write_hr_csv(hr_dir / "HR-people.csv", people)
    write_users(ldif_dir / "02-users.ldif", seed_people)
    write_groups(ldif_dir / "03-groups.ldif", seed_groups)

    belegt = sum(1 for g in seed_groups if g["members"])
    print(f"HR-CSV (Quelle):      {len(people):4d} Personen"
          f"   -> {hr_dir / 'HR-people.csv'}")
    print(f"LDAP-Accounts (Ziel): {len(seed_people):4d} Seed-Accounts"
          f" -> {ldif_dir / '02-users.ldif'}")
    print(f"LDAP-Gruppen:         {len(seed_groups):4d} Gruppen"
          f"      -> {ldif_dir / '03-groups.ldif'}")
    print()
    print(f"  {belegt} Gruppen haben Seed-Mitglieder, "
          f"{len(seed_groups) - belegt} sind leer und warten auf Provisionierung.")
    print(f"  {len(people) - len(seed_people)} Identitaeten haben noch keinen "
          f"LDAP-Account.")
    print()

    # Verteilung der Lebenszyklus-Faelle ausgeben - so ist auf einen
    # Blick erkennbar, ob genug Faelle fuer Joiner und Leaver dabei sind.
    heute = STICHTAG.isoformat()
    kuenftig  = sum(1 for p in people if p["startDate"] > heute)
    beendet   = sum(1 for p in people if p["endDate"] and p["endDate"] < heute)
    befristet = sum(1 for p in people if p["endDate"] and p["endDate"] >= heute)
    unbefr    = sum(1 for p in people
                    if not p["endDate"] and p["startDate"] <= heute)
    print(f"  Lebenszyklus (Stichtag {heute}):")
    print(f"    {kuenftig:3d} Eintritt steht bevor   (Joiner)")
    print(f"    {unbefr:3d} unbefristet aktiv")
    print(f"    {befristet:3d} befristet, noch aktiv")
    print(f"    {beendet:3d} ausgeschieden          (Leaver)")
    print()
    print("  Seed-Accounts:")
    for person in seed_people:
        print(f"    {person['employeeNumber']}  {person['uid']:<14} "
              f"{person['cn']:<22} {person['department']}")


if __name__ == "__main__":
    main()
