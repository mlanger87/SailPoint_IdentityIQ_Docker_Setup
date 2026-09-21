#!/usr/bin/env python3
# ===========================================================================
# Generator fuer die LDAP-Testdaten
# ---------------------------------------------------------------------------
# Erzeugt docker/openldap/ldif/02-users.ldif und 03-groups.ldif neu.
#
# Die Daten selbst sind englisch gehalten - so sehen Verzeichnisse in
# realen IdentityIQ-Projekten in aller Regel aus.
#
# Warum ein Generator statt handgeschriebener LDIF-Dateien:
#   - Die Datenmenge laesst sich aendern, ohne hunderte Zeilen zu pflegen.
#   - Die Verteilung (Gruppengroessen, Hierarchie) ist als Code lesbar
#     und damit nachvollziehbar.
#   - Ein fester Zufallsstartwert macht den Lauf reproduzierbar: gleicher
#     Aufruf, gleiche Daten. Das ist wichtig, damit ein neu erzeugtes
#     Verzeichnis dieselben Korrelationsergebnisse liefert wie vorher.
#
# Aufruf:
#     python scripts/generate-ldif.py
#     python scripts/generate-ldif.py --users 250 --groups 80
#
# Anschliessend muss das LDAP-Volume neu aufgebaut werden, da die LDIFs
# nur bei leerem Datenverzeichnis eingelesen werden:
#     docker compose rm -sf openldap
#     docker volume rm iiq85_ldapdata
#     docker compose up -d openldap
# ===========================================================================
import argparse
import base64
import random
import unicodedata
from pathlib import Path

BASE_DN = "dc=example,dc=com"
PEOPLE_DN = f"ou=people,{BASE_DN}"
GROUPS_DN = f"ou=groups,{BASE_DN}"
PASSWORD = "password"

# Mehrfach verwendet - als Konstante, damit ein Umbenennen an einer
# Stelle genuegt.
DEPT_HR = "Human Resources"

# Fester Startwert: gleicher Aufruf erzeugt exakt dieselben Daten.
SEED = 20250921

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
            next_number += 1
            department_people.append(person)

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
    password_b64 = base64.b64encode(PASSWORD.encode()).decode()
    lines: list[str] = [
        "# ===========================================================================",
        "# Testbenutzer",
        "# ---------------------------------------------------------------------------",
        "# ERZEUGT von scripts/generate-ldif.py - Aenderungen hier gehen beim",
        "# naechsten Lauf verloren. Stattdessen den Generator anpassen.",
        "#",
        f"# Anzahl: {len(people)}",
        f'# Passwort aller Konten: "{PASSWORD}"',
        "#",
        "# Die Attribute sind auf IdentityIQ-Uebungen hin gewaehlt:",
        "#   employeeNumber   eindeutiger Schluessel fuer die Korrelation",
        "#   manager          mehrstufige Hierarchie (Department Head, Team Lead)",
        "#   departmentNumber / l / employeeType  Merkmale fuer Rollenzuordnung",
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
        "# ERZEUGT von scripts/generate-ldif.py - Aenderungen hier gehen beim",
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
        for uid in group["members"]:
            lines.append(f"member: uid={uid},{PEOPLE_DN}")
        lines.append("")

    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Erzeugt die LDAP-Testdaten (Benutzer und Gruppen).")
    parser.add_argument("--users", type=int, default=100,
                        help="Anzahl der Benutzer (Vorgabe: 100)")
    parser.add_argument("--groups", type=int, default=50,
                        help="Anzahl der Gruppen (Vorgabe: 50)")
    parser.add_argument("--seed", type=int, default=SEED,
                        help="Zufallsstartwert fuer reproduzierbare Laeufe")
    args = parser.parse_args()

    rnd = random.Random(args.seed)
    target_dir = Path(__file__).resolve().parent.parent / "docker" / "openldap" / "ldif"

    people = build_people(args.users, rnd)
    groups = build_groups(people, args.groups, rnd)

    write_users(target_dir / "02-users.ldif", people)
    write_groups(target_dir / "03-groups.ldif", groups)

    memberships = sum(len(g["members"]) for g in groups)
    print(f"{len(people)} Benutzer  -> {target_dir / '02-users.ldif'}")
    print(f"{len(groups)} Gruppen    -> {target_dir / '03-groups.ldif'}")
    print(f"{memberships} Mitgliedschaften "
          f"({memberships / len(people):.1f} je Benutzer im Schnitt)")


if __name__ == "__main__":
    main()
