#!/usr/bin/env python3
# ===========================================================================
# Test data generator for the development environment
# ---------------------------------------------------------------------------
# Produces two outputs from ONE list of people:
#
#   data/hr/HR-people.csv                authoritative source (all people)
#   docker/openldap/ldif/02-users.ldif   seed accounts only (target system)
#   docker/openldap/ldif/03-groups.ldif  all groups (entitlements)
#   docker/postgres/04-targetdb-seed.sql  JDBC seed accounts (initdb hook)
#   data/seed/scim-users.json             SCIM seed users (loaded by the scim container)
#   data/seed/scim-groups.json            SCIM group catalog and seed memberships
#
# System roles:
#   - The HR CSV is the SOURCE. It creates the identities in IIQ.
#   - LDAP is the TARGET. IIQ creates accounts there, so apart from a few
#     seed accounts it is empty.
#
# Why seed accounts instead of a completely empty LDAP: to exercise the
# correlation case - an existing account meets a newly created identity.
# An empty directory would only cover the provisioning case.
#
# Groups, however, are COMPLETE in the directory: they are the entitlements
# IIQ must be able to assign. A target without groups has nothing worth
# provisioning.
#
# Data is in English, as in real projects.
#
# Why a generator rather than hand-maintained files:
#   - Both outputs come from the same list, so they cannot drift. The
#     employeeNumber of every seed account is guaranteed to match a CSV row.
#   - Data volume is adjustable without maintaining hundreds of lines.
#   - A fixed random seed makes runs reproducible: same call, same data.
#     Required so a rebuilt directory yields the same correlation results.
#
# Usage:
#     python scripts/generate-testdata.py
#     python scripts/generate-testdata.py --users 250 --seed-accounts 10
#
# The CSV is read by the IIQ container via bind mount and takes effect
# immediately - a change only needs a new aggregation run.
#
# The LDIFs are only loaded into an EMPTY data volume:
#     docker compose rm -sf openldap
#     docker volume rm iiq85_ldapdata
#     docker compose up -d openldap
# ===========================================================================
import argparse
import base64
import csv
import datetime
import json
import uuid
import random
import unicodedata
from pathlib import Path

BASE_DN = "dc=example,dc=com"
PEOPLE_DN = f"ou=people,{BASE_DN}"

# groupOfNames requires at least one member (RFC 4519) - an empty group
# violates the schema and slapd rejects it. Since the directory is a
# target, many groups start empty and wait for provisioning.
#
# Solution is the placeholder common in real directories: a dedicated
# entry that serves as the sole member of empty groups. IIQ hides it via
# the aggregation filter.
PLACEHOLDER_DN = f"cn=placeholder,{BASE_DN}"
GROUPS_DN = f"ou=groups,{BASE_DN}"
PASSWORD = "password"

# Used in several places - a constant so a rename is a one-line change.
DEPT_HR = "Human Resources"

# Fixed seed: same call produces exactly the same data.
SEED = 20250921

# Minimum headcount per department. Below this the hierarchy
# (department head, team lead, staff) cannot be represented.
MIN_PER_DEPARTMENT = 2

# Reference date for all date arithmetic. Deliberately NOT date.today():
# the file would change on every run and reproducibility would be gone.
# All dates are generated relative to this day.
REFERENCE_DATE = datetime.date(2026, 9, 21)

# Distribution of lifecycle cases, in percent. Chosen so every case is
# testable without the exceptions drowning out the normal case.
SHARE_FUTURE_START = 5        # joiner: start date ahead of us
SHARE_FIXED_TERM_ACTIVE = 10  # end date set, not yet reached
SHARE_LEFT = 8                # leaver: end date passed

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

# Department -> (location, cost centre, weight). Deliberately uneven:
# Sales and IT are large, Legal and Procurement small - closer to a real
# organisation than a uniform distribution.
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

# Application groups (entitlements). The number is the relative weight in
# percent - the higher, the more members.
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

# Groups that only make sense for certain departments. Prevents e.g. Legal
# getting build-server access - unrealistic and worthless for role mining.
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

# Groups whose members come preferably from management or IT. Purely
# random administrators would be unrealistic and skew role mining.
PRIVILEGED_GROUPS = {
    "app-crm-admin", "app-erp-admin", "app-ticketing-admin",
    "app-database-admin", "app-production-access",
    "app-personnel-files", "app-payroll-data", "app-contract-archive",
}


def ascii_lower(text: str) -> str:
    """Folds non-ASCII characters to ASCII - uid and mail must not contain any."""
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(c for c in decomposed if not unicodedata.combining(c)).lower()


def ldif_value(attribute: str, value: str) -> str:
    """
    Returns one LDIF line. Non-ASCII values must be base64-encoded per
    RFC 2849 (marked by the double colon), otherwise the import aborts.
    """
    if value.isascii():
        return f"{attribute}: {value}"
    encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
    return f"{attribute}:: {encoded}"


def lifecycle(rnd: random.Random) -> tuple[str, str, str]:
    """
    Rolls start and end date plus the status derived from them.

    Status is COMPUTED, not rolled independently - otherwise rows would
    contradict themselves (e.g. "active" with an end date in the past).
    Exactly such contradictions make test data useless for lifecycle
    processes.

    Returns (startDate, endDate, status) as YYYY-MM-DD.
    endDate is empty for open-ended employment.
    """
    roll = rnd.randint(1, 100)

    # Case 1: start date in the future (joiner).
    if roll <= SHARE_FUTURE_START:
        start = REFERENCE_DATE + datetime.timedelta(days=rnd.randint(3, 45))
        return start.isoformat(), "", "future"

    # Case 2: already left (leaver).
    if roll <= SHARE_FUTURE_START + SHARE_LEFT:
        start = REFERENCE_DATE - datetime.timedelta(days=rnd.randint(400, 3000))
        end = REFERENCE_DATE - datetime.timedelta(days=rnd.randint(1, 180))
        return start.isoformat(), end.isoformat(), "inactive"

    # Case 3: fixed-term but still active - end date ahead of us.
    if roll <= (SHARE_FUTURE_START + SHARE_LEFT
                + SHARE_FIXED_TERM_ACTIVE):
        start = REFERENCE_DATE - datetime.timedelta(days=rnd.randint(30, 900))
        end = REFERENCE_DATE + datetime.timedelta(days=rnd.randint(5, 120))
        return start.isoformat(), end.isoformat(), "active"

    # Case 4: the normal case - open-ended employment.
    start = REFERENCE_DATE - datetime.timedelta(days=rnd.randint(60, 5000))
    return start.isoformat(), "", "active"


def build_people(count: int, rnd: random.Random) -> list[dict]:
    """
    Distributes people across departments by weight and builds a
    three-level hierarchy:
        Department Head -> Team Lead -> Staff
    Only then is a manager certification in IIQ meaningfully testable;
    a flat list hangs everyone off the same node.
    """
    weights = [d[3] for d in DEPARTMENTS]
    total = sum(weights)
    headcounts = [max(MIN_PER_DEPARTMENT, round(count * w / total))
                  for w in weights]

    # Distribute the rounding difference.
    #
    # The per-department minimum lifts small departments; the sum then
    # exceeds the target and the difference is NEGATIVE. It used to go
    # wholesale onto headcounts[0] - for small counts the largest
    # department went negative and was silently skipped below. Measured:
    # --users 5 produced 14 people, and Sales was missing entirely.
    #
    # Now the difference is distributed stepwise, and no department drops
    # below the minimum.
    delta = count - sum(headcounts)
    if delta > 0:
        # Surplus goes to the largest department.
        headcounts[0] += delta
    else:
        # Deficit is subtracted round-robin, largest departments first,
        # as long as they stay above the minimum.
        remaining = -delta
        while remaining > 0:
            subtracted = False
            for i in range(len(headcounts)):
                if remaining == 0:
                    break
                if headcounts[i] > MIN_PER_DEPARTMENT:
                    headcounts[i] -= 1
                    remaining -= 1
                    subtracted = True
            if not subtracted:
                # All departments are at the minimum - nothing left to
                # subtract from. Should not happen given the check in
                # main().
                break

    used_uids: set[str] = set()
    used_mails: set[str] = set()
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

            # Namesakes are kept on purpose (two "Daniel Morgan" in the
            # default data exercise identity naming and correlation), but
            # the mail address must be unique: it is the SCIM userName and
            # a real HR feed never repeats one. Same suffix scheme as uid.
            base_mail = f"{ascii_lower(first)}.{ascii_lower(last)}"
            mail_local = base_mail
            suffix = 2
            while mail_local in used_mails:
                mail_local = f"{base_mail}{suffix}"
                suffix += 1
            used_mails.add(mail_local)

            # Position 0 heads the department, 1 and 2 are team leads.
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
                "mail": f"{mail_local}@example.com",
                "employeeNumber": str(next_number),
                "title": title,
                "department": department,
                "location": location,
                "costCentre": cost_centre,
                "level": level,
                "phone": f"+44 20 {rnd.randint(2000, 9999)} {rnd.randint(1000, 9999)}",
                "manager": None,
            }

            # Start, end and the status derived from them.
            start, end, status = lifecycle(rnd)
            person["startDate"] = start
            person["endDate"] = end
            person["status"] = status
            next_number += 1
            department_people.append(person)

        # Managers stay active and open-ended.
        #
        # If a department head had left, the manager reference of their
        # staff would point to an inactive identity - the manager
        # certification would run into nothing. The leaver case remains
        # testable via staff.
        for person in department_people:
            if person["level"] != "staff":
                person["endDate"] = ""
                # Only set status to active if the start is not still
                # ahead - otherwise "active" with a future startDate
                # would be a contradiction.
                if person["status"] == "inactive":
                    person["status"] = "active"

        # Wire the hierarchy within the department.
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
    Builds four kinds of groups:
      1. one group per department (full membership)
      2. one group per site
      3. organisational umbrella groups
      4. application groups with weighted, partly department-scoped
         membership
    """
    groups: list[dict] = []

    # 1. Department groups
    for department, _, _, _ in DEPARTMENTS:
        members = [p["uid"] for p in people if p["department"] == department]
        if members:
            slug = department.lower().replace(" ", "-")
            groups.append({
                "cn": f"dept-{slug}",
                "description": f"Department: {department}",
                "members": members,
            })

    # 2. Site groups
    for location in sorted({d[1] for d in DEPARTMENTS}):
        members = [p["uid"] for p in people if p["location"] == location]
        if members:
            groups.append({
                "cn": f"site-{location.lower()}",
                "description": f"Site: {location}",
                "members": members,
            })

    # 3. Organisational umbrella groups
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

    # 4. Application groups up to the target count
    remaining = count - len(groups)
    for cn, description, weight in APPLICATION_GROUPS[:max(0, remaining)]:
        scope = GROUP_DEPARTMENT_SCOPE.get(cn)
        candidates = [p for p in people
                      if scope is None or p["department"] in scope]
        if not candidates:
            continue

        # Fill privileged groups preferably from management and IT.
        # The candidate pool is narrowed BEFORE the target size is
        # computed - otherwise these groups shrink to one or two members
        # and are useless as test data.
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


def write_users(path: Path, people: list[dict], disabled: set[str]) -> None:
    """
    Writes ONLY the seed accounts. LDAP is the target - IIQ provisions
    all other accounts itself.

    Accounts whose employeeNumber is in `disabled` carry the ppolicy lock
    (pwdAccountLockedTime with the permanent-lock value), the same
    attribute the connector sets on Disable; the LDAP application maps it
    to IIQDisabled through revokeAttr/revokeVal.
    """
    password_b64 = base64.b64encode(PASSWORD.encode()).decode()
    lines: list[str] = [
        "# ===========================================================================",
        "# Seed accounts in the target system",
        "# ---------------------------------------------------------------------------",
        "# GENERATED by scripts/generate-testdata.py - edits here are lost on the",
        "# next run. Change the generator instead.",
        "#",
        f"# Count: {len(people)}",
        f'# Password of all accounts: "{PASSWORD}"',
        "#",
        "# LDAP is the TARGET here, not the source. It therefore deliberately",
        "# holds only a few accounts: IdentityIQ provisions all others from",
        "# the HR CSV.",
        "#",
        "# These few accounts exist so the correlation case can be tested -",
        "# existing account meets new identity. Their employeeNumber comes",
        "# from the same list as the CSV, so correlation is guaranteed to",
        "# match.",
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
        if person["employeeNumber"] in disabled:
            lines.append("pwdAccountLockedTime: 000001010000Z")
        lines.append("")

    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def write_groups(path: Path, groups: list[dict]) -> None:
    total = sum(len(g["members"]) for g in groups)
    lines: list[str] = [
        "# ===========================================================================",
        "# Test groups",
        "# ---------------------------------------------------------------------------",
        "# GENERATED by scripts/generate-testdata.py - edits here are lost on the",
        "# next run. Change the generator instead.",
        "#",
        f"# Group count: {len(groups)}",
        f"# Total memberships: {total}",
        "#",
        "# Layout:",
        "#   dept-*   departments (full membership)",
        "#   site-*   sites",
        "#   org-*    organisational umbrella groups",
        "#   app-*    application permissions (entitlements)",
        "#",
        "# objectClass groupOfNames - the member attribute holds full DNs.",
        "#",
        "# All groups are present even though the directory holds only a few",
        "# accounts: they are the entitlements IIQ must be able to assign.",
        "# member references only the seed accounts, since a DN would",
        "# otherwise point to a non-existent entry.",
        "#",
        "# Groups without a seed member get cn=placeholder as member:",
        "# groupOfNames requires at least one (RFC 4519). The entry is created",
        "# in 01-structure.ldif and filtered out in IIQ.",
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
            # Without this member slapd would reject the entry.
            lines.append(f"member: {PLACEHOLDER_DN}")
        lines.append("")

    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def write_hr_csv(path: Path, people: list[dict]) -> None:
    """
    Writes the authoritative HR source.

    Delimiter is the semicolon, matching the application definition
    (entry key="delimiter" value=";"). More robust than a comma here,
    since free-text fields such as the title would need escaping more
    often.

    The manager column holds the manager's employeeNumber, not the name -
    IIQ resolves the hierarchy via managerCorrelationFilter on this key.

    startDate and endDate drive the lifecycle:
        startDate in the future  -> start ahead (joiner)
        endDate empty            -> open-ended
        endDate in the future    -> fixed-term, still active
        endDate in the past      -> left (leaver)

    The status column is DERIVED from these and not rolled independently -
    otherwise contradictory rows such as "active" with a long-passed end
    date would appear.
    """
    columns = [
        "employeeNumber", "firstName", "lastName", "displayName", "email",
        "title", "department", "location", "costCentre", "employeeType",
        "phone", "managerEmployeeNumber", "startDate", "endDate", "status",
    ]

    by_uid = {p["uid"]: p for p in people}

    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter=";", quoting=csv.QUOTE_MINIMAL,
                            lineterminator="\n")
        writer.writerow(columns)
        for person in people:
            manager = by_uid.get(person["manager"]) if person["manager"] else None
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
    Selects the people that already have an LDAP account.

    Not purely random: several departments and hierarchy levels should be
    represented so correlation is not verified against a single pattern
    only.
    """
    if count >= len(people):
        return list(people)

    selected: list[dict] = []
    seen: set[str] = set()

    # First one person from as many departments as possible.
    by_department: dict[str, list[dict]] = {}
    for person in people:
        by_department.setdefault(person["department"], []).append(person)

    for department in sorted(by_department):
        if len(selected) >= count:
            break
        candidate = rnd.choice(by_department[department])
        selected.append(candidate)
        seen.add(candidate["uid"])

    # Fill the rest randomly.
    remainder = [p for p in people if p["uid"] not in seen]
    missing = count - len(selected)
    if missing > 0 and remainder:
        selected.extend(rnd.sample(remainder, min(missing, len(remainder))))

    return sorted(selected, key=lambda p: p["employeeNumber"])


def limit_groups_to_seeds(groups: list[dict],
                          seed_uids: set[str]) -> list[dict]:
    """
    Removes all members without an account in the directory.

    Necessary because member expects a real DN. A reference to a
    non-existent entry is allowed by OpenLDAP's default configuration, but
    would mislead aggregation: IIQ would report entitlements for accounts
    that do not exist.

    The group itself stays, even if it ends up empty - it is an
    entitlement IIQ must be able to assign.
    """
    limited: list[dict] = []
    for group in groups:
        limited.append({
            **group,
            "members": [uid for uid in group["members"] if uid in seed_uids],
        })
    return limited


def sql_literal(value: str) -> str:
    """Single-quoted SQL literal with the only escaping SQL needs."""
    return "'" + (value or "").replace("'", "''") + "'"


# Role sets for the JDBC seed accounts, cycled in order. Deliberately
# uneven so that entitlement aggregation has something to distinguish.
JDBC_SEED_ROLES = [
    ["TARGET_READ", "TARGET_APPROVE", "TARGET_REPORT"],
    ["TARGET_READ", "TARGET_WRITE", "TARGET_ADMIN"],
    ["TARGET_READ", "TARGET_REPORT"],
]


def write_jdbc_seed(path: Path, people: list[dict], disabled: set[str]) -> None:
    """
    Seed accounts for the JDBC target (targetdb), as an initdb-hook
    fragment. The DDL stays hand-written in 03-targetdb.sql; only the
    rows come from here, so they cannot drift from the HR CSV again
    (they did: 1030 was "Vincent Russell" in SQL and "Daniel Morgan" in
    the CSV).

    'active'/'disabled' are the target's own status vocabulary and a
    contract with 03-targetdb.sql, 26-Rules-JDBC.xml and
    27-Application-JDBC.xml.
    EmploymentType carries the HR level, which is what the create policy
    writes for provisioned accounts.
    """
    lines = [
        "-- ===========================================================================",
        "-- Seed accounts for the JDBC target - GENERATED by",
        "-- scripts/generate-testdata.py, edits here are lost on the next run.",
        "-- ===========================================================================",
        "-- Runs after 03-targetdb.sql (DDL and role catalog). IIQID equals the",
        "-- employeeNumber in data/hr/HR-people.csv, so correlation applies.",
        "",
        "\\connect targetdb",
        "",
        "INSERT INTO targetapp.\"IIQData\"",
        "    (\"IIQID\", \"Account\", \"FirstName\", \"LastName\", \"Name\", \"Email\",",
        "     \"Phone\", \"Position\", \"Department\", \"Costcenter\", \"Location\",",
        "     \"EmploymentType\", \"Status\")",
        "VALUES",
    ]
    rows = []
    for person in people:
        rows.append("    (" + ", ".join(sql_literal(v) for v in (
            person["employeeNumber"], person["uid"], person["first"],
            person["last"], person["cn"], person["mail"], person["phone"],
            person["title"], person["department"], person["costCentre"],
            person["location"], person["level"],
            "disabled" if person["employeeNumber"] in disabled else "active")) + ")")
    lines.append(",\n".join(rows) + ";")
    lines += ["", "INSERT INTO targetapp.\"IIQAccountRoles\" (\"IIQID\", \"RoleName\") VALUES"]
    pairs = []
    for i, person in enumerate(people):
        for role in JDBC_SEED_ROLES[i % len(JDBC_SEED_ROLES)]:
            pairs.append(f"    ({sql_literal(person['employeeNumber'])}, {sql_literal(role)})")
    lines.append(",\n".join(pairs) + ";")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


# SCIM group catalog: the entitlements IIQ can assign on the SCIM target.
# Static like the LDAP groups and the JDBC roles. The seed memberships are
# cycled over the seed users, uneven on purpose.
SCIM_GROUPS = [
    "ops-planning", "ops-dispatch", "ops-warehouse",
    "ops-fleet", "ops-reporting", "ops-admin",
]
SCIM_SEED_GROUPS = [
    ["ops-planning", "ops-reporting"],
    ["ops-dispatch"],
    ["ops-planning", "ops-admin"],
]


def scim_group_id(name: str) -> str:
    """
    The id the SCIM server assigns to a group (docker/scim/app.py,
    stable_id): deterministic, so 25-Bundles.xml can reference SCIM
    entitlements by id like any real SCIM target - ids are opaque there,
    the display name comes from the group aggregation.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"scim:group:{name}"))


def write_scim_seed(users_path: Path, groups_path: Path, people: list[dict],
                    disabled: set[str]) -> None:
    """
    Seed users and groups for the SCIM target as RFC 7643 resources. The
    scim container loads both files at start (bind mount), so a `down`
    costs nothing; externalId carries the employeeNumber for correlation
    and the group members are listed by that number.
    """
    users = []
    for person in people:
        users.append({
            "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
            "userName": person["mail"].split("@")[0],
            "externalId": person["employeeNumber"],
            "name": {"givenName": person["first"], "familyName": person["last"],
                     "formatted": person["cn"]},
            "displayName": person["cn"],
            "emails": [{"value": person["mail"], "primary": True, "type": "work"}],
            "title": person["title"],
            "active": person["employeeNumber"] not in disabled,
        })
    users_path.parent.mkdir(parents=True, exist_ok=True)
    users_path.write_text(json.dumps(users, indent=2) + "\n", encoding="utf-8", newline="\n")

    groups = []
    for name in SCIM_GROUPS:
        members = [p["employeeNumber"] for i, p in enumerate(people)
                   if name in SCIM_SEED_GROUPS[i % len(SCIM_SEED_GROUPS)]]
        groups.append({"id": scim_group_id(name), "displayName": name, "members": members})
    groups_path.write_text(json.dumps(groups, indent=2) + "\n", encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generates the test data: HR CSV (source) and LDAP LDIFs (target).")
    parser.add_argument("--users", type=int, default=100,
                        help="number of people in the HR CSV (default: 100)")
    parser.add_argument("--groups", type=int, default=50,
                        help="number of LDAP groups (default: 50)")
    parser.add_argument("--seed-accounts", type=int, default=8,
                        help="people that already have accounts in the targets: "
                             "all of them in LDAP, the first three also in JDBC "
                             "and SCIM (default: 5)")
    parser.add_argument("--seed", type=int, default=SEED,
                        help="random seed for reproducible runs")
    args = parser.parse_args()

    # Validate inputs instead of silently clamping them.
    minimum = MIN_PER_DEPARTMENT * len(DEPARTMENTS)
    if args.users < minimum:
        parser.error(
            f"--users must be at least {minimum}: "
            f"{len(DEPARTMENTS)} departments with {MIN_PER_DEPARTMENT} "
            f"people each. Below that the hierarchy cannot be represented.")

    max_groups = (len(DEPARTMENTS)
                  + len({d[1] for d in DEPARTMENTS})
                  + 2
                  + len(APPLICATION_GROUPS))
    if args.groups > max_groups:
        parser.error(
            f"--groups can be at most {max_groups}: "
            f"{len(DEPARTMENTS)} departments, "
            f"{len({d[1] for d in DEPARTMENTS})} sites, 2 umbrella groups "
            f"and {len(APPLICATION_GROUPS)} application groups.")
    if args.groups < 1:
        parser.error("--groups must be at least 1.")
    if args.seed_accounts < 0:
        parser.error("--seed-accounts must not be negative.")

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

    # The first five seed people also get JDBC and SCIM accounts: a
    # small cohort that exists in every target, useful for comparing how
    # the connectors report the same person.
    cross_target = seed_people[:5]

    # A few seed accounts are disabled in the target, so the aggregation
    # has to bring the account state across (link IIQDisabled=true) and
    # not only its existence. The people stay active in HR - a locked
    # account of an active employee is the realistic case. The last
    # three LDAP seeds and the last two of the cross-target cohort:
    # disjoint sets, so no person is disabled everywhere.
    ldap_disabled = {p["employeeNumber"] for p in seed_people[-3:]}
    cross_disabled = {p["employeeNumber"] for p in cross_target[-2:]}

    write_hr_csv(hr_dir / "HR-people.csv", people)
    write_users(ldif_dir / "02-users.ldif", seed_people, ldap_disabled)
    write_groups(ldif_dir / "03-groups.ldif", seed_groups)
    write_jdbc_seed(repo / "docker" / "postgres" / "04-targetdb-seed.sql", cross_target,
                    cross_disabled)
    write_scim_seed(repo / "data" / "seed" / "scim-users.json",
                    repo / "data" / "seed" / "scim-groups.json", cross_target,
                    cross_disabled)

    populated = sum(1 for g in seed_groups if g["members"])
    print(f"HR CSV (source):        {len(people):4d} people"
          f"        -> {hr_dir / 'HR-people.csv'}")
    print(f"LDAP accounts (target): {len(seed_people):4d} seed accounts"
          f" ({len(ldap_disabled)} disabled)"
          f" -> {ldif_dir / '02-users.ldif'}")
    print(f"LDAP groups:            {len(seed_groups):4d} groups"
          f"        -> {ldif_dir / '03-groups.ldif'}")
    print(f"JDBC seed (target):     {len(cross_target):4d} accounts ({len(cross_disabled)} disabled)"
          f"      -> docker/postgres/04-targetdb-seed.sql")
    print(f"SCIM seed (target):     {len(cross_target):4d} users ({len(cross_disabled)} disabled)"
          f"         -> data/seed/scim-users.json")
    print(f"SCIM groups:            {len(SCIM_GROUPS):4d} groups"
          f"        -> data/seed/scim-groups.json")
    print()
    print(f"  {populated} groups have seed members, "
          f"{len(seed_groups) - populated} are empty and await provisioning.")
    print(f"  {len(people) - len(seed_people)} identities have no LDAP account yet.")
    print()

    # Print the lifecycle distribution - shows at a glance whether there
    # are enough joiner and leaver cases.
    today = REFERENCE_DATE.isoformat()
    future     = sum(1 for p in people if p["startDate"] > today)
    left       = sum(1 for p in people if p["endDate"] and p["endDate"] < today)
    fixed_term = sum(1 for p in people if p["endDate"] and p["endDate"] >= today)
    open_ended = sum(1 for p in people
                     if not p["endDate"] and p["startDate"] <= today)
    print(f"  Lifecycle (reference date {today}):")
    print(f"    {future:3d} start ahead          (joiner)")
    print(f"    {open_ended:3d} open-ended, active")
    print(f"    {fixed_term:3d} fixed-term, still active")
    print(f"    {left:3d} left                 (leaver)")
    print()
    print("  Seed accounts:")
    for person in seed_people:
        print(f"    {person['employeeNumber']}  {person['uid']:<14} "
              f"{person['cn']:<22} {person['department']}")


if __name__ == "__main__":
    main()
