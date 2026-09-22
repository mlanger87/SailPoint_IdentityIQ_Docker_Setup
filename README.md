# SailPoint IdentityIQ 8.5 — Docker dev environment

One `docker compose up -d` gives you IdentityIQ 8.5 on Tomcat 9 / OpenJDK 21 /
PostgreSQL 17, an authoritative HR source, four provisioning targets and a
date-driven joiner/leaver lifecycle. Local development only — see
[Security posture](#security-posture).

Design rationale and every pitfall we hit, with measurements, live in
[CLAUDE.md](CLAUDE.md). Read it before changing anything non-trivial.

## Prerequisites

- Docker Desktop (tested with 29.3.1), ≥ 8 GB RAM for the engine
- The SailPoint package `SailPoint_identityiq-8.5_Software_Package.zip` — licensed,
  not in the repo
- Python 3 on the host only if you regenerate test data

## First run

```powershell
# 1. package
copy SailPoint_identityiq-8.5_Software_Package.zip installer\

# 2. checks Docker, RAM, ports; writes .env from .env.example
.\scripts\setup.ps1          # or scripts/setup.sh

# 3. build + start; first run 15–25 min (WAR unpack, DDL, base import)
docker compose up -d
docker compose logs -f iiq-init

# 4. verify
bash scripts/verify.sh
```

Subsequent starts take about a minute. `iiq` starts only after `iiq-init` exited 0;
if it does not come up, read `docker compose logs iiq-init`.

## Endpoints

All ports bind to `127.0.0.1`. Change them in `.env`.

| Service | URL | Credentials |
|---|---|---|
| IdentityIQ | http://localhost:8080/identityiq | `spadmin` / `admin` |
| Mailpit (mail sink) | http://localhost:8025 | — |
| DBGate (SQL) | http://localhost:5050 | four connections preconfigured |
| LDAP UI | http://localhost:5080 | `admin` / `adminpassword` |
| SCIM server | http://localhost:8100 | Bearer `secret` |
| Mock REST API | http://localhost:8200 | Bearer `mocktoken` or Basic `iiq`/`iiqpassword` |
| PostgreSQL | `localhost:5432` | `identityiq` / `identityiq` |
| OpenLDAP | `localhost:1389` | `cn=admin,dc=example,dc=com` / `adminpassword` |
| JDWP | `localhost:8000` | attach from IDE; Tomcat does not wait |

## Daily use

```powershell
.\scripts\iiq.ps1 status | console | import | logs | psql | shell | restart | reset
```

Ports and credentials shown by the scripts come from `.env` via `scripts/env.sh` /
`env.ps1`; change a port in `.env` and every script follows.

- **Custom objects:** XML into `data/objects/`, then `.\scripts\iiq.ps1 import`. Files
  import alphabetically in one console session (one JVM start instead of one per
  file); the numeric prefix is the dependency order.
- **Plugins:** ZIPs into `data/plugins/`, then `import`.
- **Certificates:** `.cer/.crt/.pem` into `data/certs/` → Java truststore on the next
  container start (both `iiq-init` and `iiq`; the log line is `imported.`). Key
  material in that directory is gitignored.
- **Removing an object:** deleting its file does not delete it from IIQ — `import` only
  adds and merges. Use `delete <Class> "<name>"` in the console.
- **Ad-hoc SQL:** DBGate, or `.\scripts\iiq.ps1 psql`. Tables live in schema
  `identityiq`, not `public`; `search_path` is preset per role.

## System landscape

| Object | Kind | Backing store | Seed data |
|---|---|---|---|
| `HR-Application` | **authoritative source**, DelimitedFile | `data/hr/HR-people.csv` (bind-mounted, edits are live) | 100 people |
| `LDAP-Target` | target, LDAP | `openldap` | 8 accounts (3 disabled), 50 groups |
| `JDBC-Target` | target, JDBC | `targetdb` in the same Postgres | 5 accounts (2 disabled), 6 roles |
| `SCIM-Target` | target, SCIM 2.0 | `scim` (own image, `docker/scim`) | 5 users (2 disabled), 6 groups |
| `WebService-Target` | target, generic REST | `mockapi` | 6 accounts (2 disabled), 5 groups |

Targets are almost empty on purpose: IIQ creates the accounts. The few seed accounts
exist so correlation (existing account meets new identity) is exercised as well, and
some of them start disabled in the target (LDAP `pwdAccountLockedTime`, JDBC
`Status=disabled`, SCIM `active=false`, REST `status=DISABLED`) so the account state
reaches IIQ, not only the account.
Correlation key everywhere, including the HR source, is the personnel number
(`employeeNumber`). Identities are named `first.last`; a namesake gets the personnel
number appended (`daniel.morgan`, `daniel.morgan.1030`), the display name stays the
full name.

Roles (`data/objects/25-Bundles.xml`) are assigned from HR attributes and drive the
account creation on every target: `employee` (everyone active) → LDAP basic groups;
`it-staff`, `sales-staff` → more LDAP groups; `manager` → LDAP manager groups and the
JDBC approver role; `finance-staff` → JDBC roles; `operations-staff` → SCIM groups;
`hr-staff` → REST portal groups. Each business role requires one IT role that carries
the entitlements of exactly one target.

### The HR feed

Semicolon-separated, header row. Columns: `employeeNumber`, `firstName`, `lastName`,
`displayName`, `email`, `title`, `department`, `location`, `costCentre`,
`employeeType`, `phone`, `managerEmployeeNumber`, `startDate`, `endDate`, `status`.

- `managerEmployeeNumber` builds a three-level hierarchy (department head → team lead
  → staff); managers never leave, so no link points at an inactive identity.
- `startDate`/`endDate` drive the lifecycle; `status` is derived from them
  (`future` / `active` / `inactive`), never rolled independently.
- Default distribution (seed 20250921): 90 active, 6 future joiners, 4 leavers, 10
  fixed-term still active. Eight departments, unequal sizes (Sales 22 … Legal 4).
- Two people share a name on purpose (`Daniel Morgan`, 1007 and 1030) to exercise
  correlation and identity naming; mail addresses are unique (`daniel.morgan2@…`).

### Lifecycle demo

The triggers fire on a *transition* of `inactive`. On a fresh database the four
leavers are already inactive when their identity is created, so the first refresh
starts no leaver workflow. To watch one:

1. In `data/hr/HR-people.csv` set an active person's `endDate` to yesterday and
   `status` to `inactive` (the file is bind-mounted, no restart).
2. Run `HR Aggregation`, then `Refresh Identity Cube`.
3. Setup → Tasks → results shows `HR Leaver: <name>`; every target account of that
   person is disabled: the LDAP entry gets `pwdAccountLockedTime: 000001010000Z`
   (operational attribute — ask for it by name in `ldapsearch`), the REST mock
   account shows `status: DISABLED`, the links show `iiqDisabled=true`. Setup →
   Provisioning Transactions lists every operation. JDBC and SCIM accounts exist
   only for the seed people, so pick one of those to see all four targets.
4. Undo the CSV edit and run both tasks again: `HR Joiner: <name>`, the lock value
   is removed, the REST status is back to `ACTIVE`, the links are enabled.

### Running the aggregation

Objects are imported at init; nothing is aggregated automatically. Setup → Tasks, in
this order:

1. HR Aggregation — creates the identities
2. LDAP Group Aggregation, then LDAP Account Aggregation
3. JDBC Aggregation
4. SCIM Group Aggregation, then SCIM Aggregation
5. WebService Group Aggregation, then WebService Aggregation
6. Refresh Identity Cube — roles, manager status, lifecycle triggers, provisioning

Groups before accounts, or entitlements reference unknown groups. From the console
use quotes: `run "LDAP Group Aggregation"`, and keep the console open until the task
finishes — `quit` kills the scheduler.

### Regenerating test data

```powershell
python scripts\generate-testdata.py --users 250 --groups 80 --seed-accounts 10
```

Writes the CSV, both LDIFs, the JDBC seed SQL and the SCIM seed JSON (users and
groups) from one person list; the fixed seed makes the output reproducible, and the
first five LDAP seed people also exist in JDBC and SCIM. Minimum `--users` is 16
(8 departments × 2). The CSV and the SCIM seed are live (bind mounts; the SCIM server
re-reads its seed on `docker compose restart scim`); the LDIFs and the JDBC seed load
only into an empty volume:

```powershell
docker compose rm -sf openldap; docker volume rm iiq85_ldapdata; docker compose up -d openldap
```

After such a reset run `LDAP Account Aggregation` (drops the links of the vanished
entries) and `Refresh Identity Cube` (recreates them from the roles).

## Layout

```
docker-compose.yml            services, health checks, loopback ports
docker-compose.override.yml   dev extras: JDWP, log bind-mount (auto-loaded)
.env                          ports, credentials, heap, IIQ_EXTRA_OPTS (gitignored)
installer/                    the SailPoint ZIP (gitignored)
docker/iiq/                   Tomcat 9 + JDK 21 image, entrypoint, patch scripts
docker/postgres/              PG 17 image with IIQ DDL and targetdb as initdb hooks
docker/mockapi/               REST mock (stdlib Python, ~50 MB image)
docker/scim/                  SCIM 2.0 server (stdlib Python, same construction)
docker/openldap/ldif/         01-structure (hand-written), 02/03 (generated)
data/objects/                 IIQ objects, imported in prefix order on every init
data/hr/                      HR CSV (generated)
data/seed/                    SCIM seed users and groups (generated, read by scim)
scripts/env.sh, env.ps1       single source for ports/credentials on the host
data/plugins/, data/certs/    mounted read-only into iiq
scripts/                      setup, verify, iiq wrapper, test-data generator
```

Containers: `postgres`, `iiq-init` (runs once, exits), `iiq`, `mailpit`, `openldap`,
`ldap-ui`, `dbgate`, `scim`, `mockapi`. Six have health checks; `iiq` waits for
`postgres` healthy and `iiq-init` completed.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `iiq` never starts | `iiq-init` exited non-zero. `docker compose logs iiq-init`; the entrypoint greps console output for real failures. |
| Login page HTTP 000 right after start | Tomcat needs 1–3 min. `docker compose logs -f iiq`. |
| Aggregation "Success" but 0 accounts / 0 roles / no manager | Silent misconfiguration — see the pattern in CLAUDE.md. Compare expected vs. actual with an isolated rule/filter call. |
| Task stuck "running" after a crash | `UPDATE spt_task_result SET completion_status='Terminated' WHERE completion_status IS NULL;` |
| REST create/update fails, unclear what was sent | The override sets `LOG_BODIES=true` on the mock: `docker compose logs mockapi` shows every request body. |
| `Container name is already in use`, but `docker rm` finds nothing | `docker compose down --remove-orphans` (no `-v`). If `docker ps` hangs: restart Docker Desktop; volumes survive. Never force-kill it. |
| `exec format error` on a third-party image | containerd store picks the first manifest platform. `platform: linux/amd64`, or another image. |
| `bad interpreter` in a container | CRLF. `git ls-files --eol scripts/` must show `i/lf w/lf`. |
| Changed DB passwords in `.env` | They are baked in: `docker compose build && docker compose down -v && docker compose up -d`. |
| Full reset | `.\scripts\iiq.ps1 reset` then `docker compose up -d`. |

## Security posture

This is a laptop dev environment, and the choices reflect that:

- Credentials are plaintext defaults in `.env.example`, `iiq.properties` and the target
  XML. `iiq encrypt` is not used because the keystore would sit in the same image.
- No TLS anywhere; IIQ debug pages on; JDWP enabled.
- Mitigations that are in place regardless: every published port is loopback-only,
  the IIQ and mock images run as UID 1000 with `cap_drop: [ALL]`, every service has
  `no-new-privileges`, all images are pinned by tag or digest, the JDBC driver download
  is checksum-verified, no secret is printed to a container log, `.env`, the installer
  and key material under `data/` are gitignored.
- Known and accepted: JDWP is reachable from sibling containers on the compose network;
  DBGate and Mailpit have no login (both loopback-only).

Do not expose any of this beyond `localhost`.
