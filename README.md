# SailPoint IdentityIQ 8.5 — Docker dev environment

A complete IdentityIQ development environment that starts with one command:
IdentityIQ 8.5 on Tomcat 9 / OpenJDK 21 / PostgreSQL 17, split into a UI node and a
batch node, with an authoritative HR source, four provisioning targets (LDAP, JDBC,
SCIM 2.0, generic REST) and a date-driven joiner/leaver lifecycle. Everything is
pre-wired: aggregate, assign roles, watch accounts appear in the targets.

For local development only — see [Security posture](#security-posture).

**You need to supply one thing:** the licensed SailPoint installation package. It is
not, and cannot be, part of this repository.

Design rationale and every pitfall hit while building this, each with the measurement
that exposed it, live in [CLAUDE.md](CLAUDE.md). Read it before changing anything
non-trivial.

---

## Contents

- [What you get](#what-you-get)
- [Prerequisites](#prerequisites)
- [Setup](#setup) — from zero to a running instance
- [First steps in the UI](#first-steps-in-the-ui)
- [Endpoints](#endpoints)
- [Daily use](#daily-use)
- [Two nodes: UI and batch](#two-nodes-ui-and-batch)
- [System landscape](#system-landscape)
- [Layout](#layout)
- [Troubleshooting](#troubleshooting)
- [Security posture](#security-posture)

---

## What you get

| | |
|---|---|
| **IdentityIQ 8.5** | Tomcat 9, OpenJDK 21, two nodes against one database |
| **PostgreSQL 17** | IIQ schema created from SailPoint's own DDL at image build |
| **HR source** | 100 generated people in a CSV, authoritative, correlated by personnel number |
| **Four targets** | OpenLDAP, a JDBC database, a SCIM 2.0 server, a generic REST API |
| **Roles** | seven business and IT roles that provision accounts on every target |
| **Lifecycle** | joiner and leaver workflows driven by `startDate` / `endDate` in the feed |
| **Tooling** | Mailpit as mail sink, DBGate for SQL, an LDAP browser, JDWP debug port |

Nothing here is a stub: every connector really talks to a running server, and the
provisioning path is exercised end to end. The numbers a correct fresh setup
produces are recorded in [CLAUDE.md](CLAUDE.md#reference-run) — if your run differs,
something regressed.

---

## Prerequisites

| | |
|---|---|
| **Docker Desktop** or Docker Engine with Compose v2 | tested with Docker Desktop 29.3.1 |
| **RAM for the Docker engine** | 8 GB minimum, 16 GB comfortable — two IIQ nodes take 3 GB each |
| **Disk** | about 15 GB: the unpacked WAR alone is ~1 GB in 8,984 files |
| **The SailPoint package** | `SailPoint_identityiq-8.5_Software_Package.zip`, 770 MB |
| **Git** | with LF checkout for shell scripts — see the note under [Windows](#a-note-for-windows-users) |
| **Python 3** | on the host, and only if you want to regenerate the test data |

The installation package is licensed software distributed by SailPoint to customers
and partners through their support portal. It is **not** in this repository, it is
gitignored, and it will not be provided here. Without it nothing builds.

### A note for Windows users

The shell scripts inside the containers must have LF line endings. The repository
enforces this through `.gitattributes`, so a normal `git clone` is fine. If you ever
see `bad interpreter: No such file or directory` in a container log, check with:

```bash
git ls-files --eol scripts/
```

Every entry must read `i/lf w/lf`. Do not set `core.autocrlf=true` globally and
expect this repository to work.

---

## Setup

### 1. Clone and place the package

```bash
git clone https://github.com/mlanger87/SailPoint_IdentityIQ_Docker_Setup.git
cd SailPoint_IdentityIQ_Docker_Setup
```

Copy your SailPoint package into `installer/`. The exact file name does not matter;
the build picks up the first `.zip` in that folder.

```powershell
copy C:\Downloads\SailPoint_identityiq-8.5_Software_Package.zip installer\
```

```bash
cp ~/Downloads/SailPoint_identityiq-8.5_Software_Package.zip installer/
```

If you also have a patch JAR (for example `identityiq-8.5p1.jar`), put it in the same
folder and set `IIQ_PATCH=p1` in `.env` in the next step. Without a patch, leave
`IIQ_PATCH` empty.

### 2. Run the setup script

```powershell
.\scripts\setup.ps1
```

```bash
./scripts/setup.sh
```

It checks that Docker is reachable, that the engine has enough memory, that the
package is present and that no published port is already taken, then creates `.env`
from `.env.example`. It changes nothing else. Review `.env` if you want different
ports, a different heap or different passwords — the database passwords are baked
into the image at build time, so change them now rather than later.

### 3. Build and start

```bash
docker compose up -d
```

The first build takes **15 to 25 minutes**: the 742 MB WAR is unpacked into roughly
8,984 files, the PostgreSQL image is prepared with SailPoint's 9,146-line DDL, and
the three small Python images are built. Subsequent starts take about a minute.

After the images are built, `iiq-init` runs once: it creates the schema, imports the
base configuration, applies a patch if you configured one, then imports every XML in
`data/objects/` and exits. Both IIQ nodes wait for that to finish. Follow it with:

```bash
docker compose logs -f iiq-init
```

The line you are waiting for is the container exiting with code 0. If it exits
non-zero, the log holds the reason — the init script inspects console output for real
failures rather than trusting exit codes, which IIQ does not set reliably.

### 4. Verify

```bash
bash scripts/verify.sh
```

Eight groups of checks, from container health through the database schema, both IIQ
nodes, the Quartz scheduler and every target system. It should end with
`=== All checks passed ===`. If a check fails it prints the command to investigate
with.

Then open http://localhost:8080/identityiq and log in as `spadmin` / `admin`.

### 5. Load the data

Nothing is aggregated automatically — the objects are imported, but the tasks have to
run. In the UI under **Setup → Tasks**, run these in order. Groups before accounts,
or entitlements reference groups that do not exist yet and end up without a display
name.

1. `HR Aggregation` — creates the 100 identities
2. `LDAP Group Aggregation`, then `LDAP Account Aggregation`
3. `JDBC Aggregation`
4. `SCIM Group Aggregation`, then `SCIM Aggregation`
5. `WebService Group Aggregation`, then `WebService Aggregation`
6. `Refresh Identity Cube` — roles, manager relationships, lifecycle triggers and the
   provisioning that creates accounts in every target

The last task is where it gets interesting: role assignment creates around 130
accounts across the four targets. Watch **Setup → Provisioning Transactions**
afterwards; every entry should read `Success`.

From the console the same thing works, but quote names that contain spaces:

```bash
docker compose exec iiq iiq console
> run "LDAP Group Aggregation"
```

`run` returns immediately — poll the task result rather than assuming it finished,
and always end a console session with `quit`.

### Full reset

```powershell
.\scripts\iiq.ps1 reset      # asks for confirmation, then: docker compose down -v
docker compose up -d
```

This deletes the database and every volume, so the next start rebuilds the whole
environment from scratch. Images are kept, so it takes a few minutes, not 25.

---

## First steps in the UI

Once the task chain has run, these are worth looking at:

- **Identities → Identity Warehouse** — 105 identities, each with links on the targets
  their roles demanded. Open one and look at the Entitlements tab.
- **Setup → Roles** — seven roles. The business roles (`employee`, `manager`,
  `it-staff`, …) are assigned by selectors on HR attributes; each requires an IT role
  that carries the entitlements of exactly one target.
- **Setup → Provisioning Transactions** — every account creation, with the actual
  request sent to the connector.
- **Global Settings → Servers** — both nodes with their heartbeat, and which services
  run where.
- **The targets themselves** — the LDAP browser on port 5080, DBGate for the JDBC
  target, `curl` against the SCIM server on 8100 and the REST mock on 8200.

To see the lifecycle in action, follow [Lifecycle demo](#lifecycle-demo).

---

## Endpoints

All ports bind to `127.0.0.1` only. Change them in `.env`; the scripts read the same
file, so they follow automatically.

| Service | URL | Credentials |
|---|---|---|
| IdentityIQ, UI node | http://localhost:8080/identityiq | `spadmin` / `admin` |
| IdentityIQ, batch node | http://localhost:8081/identityiq | same; runs the tasks, see [Two nodes](#two-nodes-ui-and-batch) |
| Mailpit (mail sink) | http://localhost:8025 | — |
| DBGate (SQL) | http://localhost:5050 | four connections preconfigured |
| LDAP UI | http://localhost:5080 | `admin` / `adminpassword` |
| SCIM server | http://localhost:8100 | Bearer `secret` |
| Mock REST API | http://localhost:8200 | Bearer `mocktoken` or Basic `iiq`/`iiqpassword` |
| PostgreSQL | `localhost:5432` | `identityiq` / `identityiq` |
| OpenLDAP | `localhost:1389` | `cn=admin,dc=example,dc=com` / `adminpassword` |
| JDWP | `localhost:8000` | attach from your IDE; Tomcat does not wait for it |

---

## Daily use

```powershell
.\scripts\iiq.ps1 status | console | import | logs | psql | shell | restart | reset
```

- **Custom objects:** XML into `data/objects/`, then `.\scripts\iiq.ps1 import`. Files
  import alphabetically in one console session (one JVM start instead of one per
  file); the numeric prefix is the dependency order, and references must point
  backwards.
- **Plugins:** ZIPs into `data/plugins/`, then `import`.
- **Certificates:** `.cer/.crt/.pem` into `data/certs/` → Java truststore on the next
  container start, on both IIQ nodes; the log line to look for is `imported.`. Key
  material in that directory is gitignored.
- **Removing an object:** deleting its file does not delete it from IIQ — import only
  adds and merges. Use `delete <Class> "<name>"` in the console.
- **Ad-hoc SQL:** DBGate, or `.\scripts\iiq.ps1 psql`. Tables live in a schema named
  `identityiq`, not in `public`; the `search_path` is preset per role, but explicit
  prefixes are safer.

---

## Two nodes: UI and batch

The stack runs IdentityIQ twice against one database, the way most installations are
shaped: `iiq` serves the UI, `iiq-batch` runs the Task scheduler and the Request
processor. Both come from the same image; the only differences are the server name
(`IIQ_NODE` / `IIQ_BATCH_NODE` in `.env`, passed as `-Diiq.hostname`) and the port.

`data/objects/05-ServiceDefinitions.xml` pins the `Task`, `Request` and
`BundleProfileRelation` services to `hosts="iiq-batch"`; every other service stays
`global`. All three are background services — `Request` is the processor for
asynchronous `Request` objects (workflow steps, mails, provisioning retries), not the
web tier. IIQ starts a request processor on every node regardless, so that requests
addressed to one specific host reach it; the UI node's About page therefore shows the
request scheduler as started while the task scheduler is stopped. That is expected.

**Global Settings → Servers** shows both nodes with their heartbeat and lets you move
services between them at runtime, but such a change lives in the database only and is
lost on a volume reset. The file is the durable configuration. If you rename the batch
node, change `.env` and the XML together — with a mismatch no node runs the Task
service, tasks stay pending forever and nothing logs an error. `verify.sh` checks for
exactly that.

Tasks started from the UI on port 8080 or from the console run on the batch node; the
task result records the executing host. There is no load balancer: two ports, no
sticky sessions. Debugging (JDWP) and the log bind mount `data/logs/` belong to the UI
node; the batch node logs to `data/logs/batch/`.

---

## System landscape

| Object | Kind | Backing store | Seed data |
|---|---|---|---|
| `HR-Application` | **authoritative source**, DelimitedFile | `data/hr/HR-people.csv` (bind-mounted, edits are live) | 100 people |
| `LDAP-Target` | target, LDAP | `openldap` | 8 accounts (3 disabled), 50 groups |
| `JDBC-Target` | target, JDBC | `targetdb` in the same Postgres | 5 accounts (2 disabled), 6 roles |
| `SCIM-Target` | target, SCIM 2.0 | `scim` (own image, `docker/scim`) | 5 users (2 disabled), 6 groups |
| `WebService-Target` | target, generic REST | `mockapi` | 6 accounts (2 disabled), 5 groups |

Targets are almost empty on purpose: IIQ creates the accounts. The few seed accounts
exist so correlation (an existing account meets a new identity) is exercised as well,
and some of them start disabled in the target (LDAP `pwdAccountLockedTime`, JDBC
`Status=disabled`, SCIM `active=false`, REST `status=DISABLED`) so the account *state*
reaches IIQ, not only the account.

Correlation key everywhere, including the HR source, is the personnel number
(`employeeNumber`). Identities are named `first.last`; a namesake gets the personnel
number appended (`daniel.morgan`, `daniel.morgan.1030`), while the display name stays
the full name.

Roles (`data/objects/25-Bundles.xml`) are assigned from HR attributes and drive
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
  fixed-term still active. Eight departments of unequal size (Sales 22 … Legal 4).
- Two people share a name on purpose (`Daniel Morgan`, 1007 and 1030) to exercise
  correlation and identity naming; mail addresses stay unique (`daniel.morgan2@…`).

The file is bind-mounted, so edits take effect on the next aggregation without a
restart.

### Lifecycle demo

The triggers fire on a *transition* of the `inactive` attribute. On a fresh database
the four leavers are already inactive when their identity is created, so the first
refresh starts no leaver workflow. To watch one:

1. In `data/hr/HR-people.csv` set an active person's `endDate` to yesterday and
   `status` to `inactive`.
2. Run `HR Aggregation`, then `Refresh Identity Cube`.
3. **Setup → Tasks → results** shows `HR Leaver: <name>`, and every target account of
   that person is disabled: the LDAP entry gets `pwdAccountLockedTime: 000001010000Z`
   (an operational attribute — ask for it by name in `ldapsearch`), the REST mock
   account shows `status: DISABLED`, the links show `iiqDisabled=true`. **Setup →
   Provisioning Transactions** lists every operation. JDBC and SCIM accounts exist
   only for people who have the matching role, so pick one of the seed people to see
   all four targets react.
4. Undo the CSV edit and run both tasks again: `HR Joiner: <name>`, the lock value is
   removed, the REST status is back to `ACTIVE`, the links are enabled.

### Regenerating test data

```powershell
python scripts\generate-testdata.py --users 250 --groups 80 --seed-accounts 10
```

Writes the CSV, both LDIFs, the JDBC seed SQL and the SCIM seed JSON (users and
groups) from one person list; the fixed seed makes the output reproducible, and the
first five LDAP seed people also exist in JDBC and SCIM. Minimum `--users` is 16
(8 departments × 2).

The CSV and the SCIM seed are live (bind mounts; the SCIM server re-reads its seed on
`docker compose restart scim`). The LDIFs and the JDBC seed load only into an empty
volume:

```powershell
docker compose rm -sf openldap; docker volume rm iiq85_ldapdata; docker compose up -d openldap
```

After such a reset run `LDAP Account Aggregation` (drops the links of the vanished
entries) and `Refresh Identity Cube` (recreates them from the roles).

---

## Layout

```
docker-compose.yml            services, health checks, loopback ports
docker-compose.override.yml   dev extras: JDWP, log bind-mounts (auto-loaded)
.env                          ports, credentials, heap, IIQ_EXTRA_OPTS (gitignored)
installer/                    the SailPoint ZIP goes here (gitignored)
docker/iiq/                   Tomcat 9 + JDK 21 image, entrypoint, patch scripts
docker/postgres/              PG 17 image with IIQ DDL and targetdb as initdb hooks
docker/mockapi/               REST mock (stdlib Python, ~50 MB image)
docker/scim/                  SCIM 2.0 server (stdlib Python, same construction)
docker/openldap/ldif/         01-structure (hand-written), 02/03 (generated)
data/objects/                 IIQ objects, imported in prefix order on every init
data/hr/                      HR CSV (generated)
data/seed/                    SCIM seed users and groups (generated, read by scim)
data/plugins/, data/certs/    mounted read-only into both IIQ nodes
scripts/env.sh, env.ps1       single source for ports/credentials on the host
scripts/                      setup, verify, iiq wrapper, test-data generator
```

Containers: `postgres`, `iiq-init` (runs once, exits), `iiq`, `iiq-batch`, `mailpit`,
`openldap`, `ldap-ui`, `dbgate`, `scim`, `mockapi`. Seven have health checks; both IIQ
nodes wait for `postgres` healthy and `iiq-init` completed.

Generated files are committed but never hand-edited — change the generator instead:
`data/hr/HR-people.csv`, `docker/openldap/ldif/02-users.ldif`, `03-groups.ldif`,
`docker/postgres/04-targetdb-seed.sql`, `data/seed/scim-users.json`,
`data/seed/scim-groups.json`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `iiq` / `iiq-batch` never start | `iiq-init` exited non-zero. `docker compose logs iiq-init`; the entrypoint greps console output for real failures. |
| Build fails with "No installation package found" | The ZIP is missing from `installer/`, or has a different extension. |
| Login page HTTP 000 right after start | Tomcat needs 1–3 min. `docker compose logs -f iiq iiq-batch`. |
| A task never leaves "Pending" | Nothing runs the Task service: the batch node is down, or its `IIQ_BATCH_NODE` differs from `hosts=` in `05-ServiceDefinitions.xml`. Global Settings → Servers shows which node is alive. |
| Aggregation "Success" but 0 accounts / 0 roles / no manager | Silent misconfiguration — see the pattern in CLAUDE.md. Compare expected against actual by running the rule or filter in isolation. |
| Task stuck "running" after a crash | `UPDATE spt_task_result SET completion_status='Terminated' WHERE completion_status IS NULL;` |
| REST create/update fails, unclear what was sent | The override sets `LOG_BODIES=true` on the mock: `docker compose logs mockapi` shows every request body. |
| `Container name is already in use`, but `docker rm` finds nothing | `docker compose down --remove-orphans` (no `-v`). If `docker ps` hangs: restart Docker Desktop; volumes survive. Never force-kill it. |
| `exec format error` on a third-party image | The containerd image store picks the first manifest platform. Set `platform: linux/amd64`, or use another image. |
| `bad interpreter` in a container | CRLF line endings. `git ls-files --eol scripts/` must show `i/lf w/lf`. |
| Changed DB passwords in `.env` | They are baked into the image: `docker compose build && docker compose down -v && docker compose up -d`. |
| Out of memory, containers killed | Two IIQ nodes take 3 GB each by default. Lower `IIQ_HEAP` / `IIQ_BATCH_HEAP`, or give Docker more RAM. |
| Full reset | `.\scripts\iiq.ps1 reset`, then `docker compose up -d`. |

---

## Security posture

This is a laptop development environment, and the choices reflect that:

- Credentials are plaintext defaults in `.env.example`, `iiq.properties` and the
  target XML. `iiq encrypt` is deliberately not used: the keystore would sit in the
  same image, which buys nothing. A production setup would mount it externally.
- No TLS anywhere; IIQ debug pages are on; JDWP is enabled.
- Mitigations that are in place regardless: every published port is loopback-only,
  the IIQ and mock images run as UID 1000 with `cap_drop: [ALL]`, every service has
  `no-new-privileges`, all images are pinned by tag or digest, the JDBC driver
  download is checksum-verified, no secret is printed to a container log, and `.env`,
  the installer and key material under `data/` are gitignored.
- Known and accepted: JDWP is reachable from sibling containers on the compose
  network; DBGate and Mailpit have no login (both loopback-only).

**Do not expose any of this beyond `localhost`, and do not use it as a base for a
production deployment without revisiting every point above.**

---

## License and attribution

The contents of this repository — compose files, images, scripts, generated test data
and IdentityIQ configuration objects — are published under the
[MIT License](LICENSE).

SailPoint IdentityIQ itself is commercial software owned by SailPoint Technologies
and is licensed separately. This repository contains no part of it and neither
distributes nor circumvents any license: you need your own legally obtained copy of
the installation package.

Third-party images used: `postgres`, `tomcat`, `bitnami/openldap`, `axllent/mailpit`,
`dnknth/ldap-ui`, `dbgate/dbgate`. Each is pinned by tag or digest in
`docker-compose.yml`.
