# CLAUDE.md

Working knowledge for this repository: verified platform facts, the reasoning behind
design decisions, and every pitfall that cost time — each with the measurement that
exposed it. Written for senior developers. If a claim here conflicts with the running
instance, the instance wins; update this file.

## What this is

A local Docker development environment for **SailPoint IdentityIQ 8.5** on
**Tomcat 9 / OpenJDK 21 / PostgreSQL 17**, with a complete miniature system landscape:
an authoritative HR source and four provisioning targets (LDAP, JDBC, SCIM 2.0,
generic REST), plus joiner/leaver lifecycle driven by dates in the HR feed.

The IIQ installation package is licensed and **not** in the repository. Drop it into
`installer/`.

## Working rules

- **Commits carry no AI attribution.** Author is Michael Langer. No `Co-Authored-By`,
  no "Generated with".
- **Language:** English everywhere in the repo — docs, comments, script output, commit
  messages. Conversation with the maintainer is German.
- **Verify against the instance, not against memory or web examples.** The IIQ docs are
  login-gated; most public XML samples target older releases. Sources of truth, in
  order: the Installation Guide inside the ZIP, the runtime DTD (`dtd /tmp/sp.dtd` in
  the console), reflection against the running JVM, the shipped templates under
  `WEB-INF/config/connector/`.
- **Changing `.env` DB credentials requires a rebuild** — they are baked into the DDL
  and `iiq.properties`:
  ```
  docker compose build && docker compose down -v && docker compose up -d
  ```
- **Custom IIQ objects go to `data/objects/`.** Numeric prefix controls import order
  (`import_folder()` sorts with `LC_ALL=C`); references must point backwards. Every file
  is re-imported on every init run. **Import never deletes:** an object removed or
  renamed in the files stays in the database until you `delete <Class> "<name>"` in the
  console or reset the volume.
- **Ports and credentials on the host side come from `scripts/env.sh` / `env.ps1`**
  (`.env` with the compose defaults). Do not hard-code a port or URL in a script again;
  that is how SCIM and the mock API went missing from four copies of the endpoint list.
- **Every target re-seeds itself:** Postgres from initdb hooks (empty volume only),
  LDAP from the LDIFs (empty volume only), the REST mock from the live CSV and the SCIM
  server from `data/seed/*.json` on every start. Nothing has to be replayed by hand
  after a `down`.
- **Generated artifacts are committed but never hand-edited:** `data/hr/HR-people.csv`,
  `docker/openldap/ldif/02-users.ldif`, `03-groups.ldif`,
  `docker/postgres/04-targetdb-seed.sql`, `data/seed/scim-users.json`,
  `data/seed/scim-groups.json`. Change the generator. One person list feeds every target; the first five LDAP seed people also
  exist in JDBC and SCIM.
- **Before editing a shell script on Windows:** `git ls-files --eol scripts/` must show
  `i/lf w/lf`. A literal CR byte anywhere flips the file to binary and disables
  `eol=lf` normalization (happened to `verify.sh`; seven CR bytes inside `tr -d`).

## Verified platform facts

Source: `doc/8.5_IdentityIQ_Installation_Guide.pdf` inside the package, plus direct
inspection of the WAR.

| Topic | Fact | Evidence |
|---|---|---|
| Java | OpenJDK 21 and 17 supported | Guide p.3 |
| App server | **Tomcat 9.0 only** | Guide p.2 |
| Database | PostgreSQL 17/16, MySQL 8.4/8.0, MSSQL 2022/2019, Oracle 19c | Guide p.3 |
| MariaDB | not supported (absent from the list) | Guide p.3 |
| Default login | `spadmin` / `admin` | Guide p.17 |
| Bytecode | Java 11 (major 55) — runs on 21 | `identityiq.jar` |

**Tomcat 9 is non-negotiable.** IIQ 8.5 is `javax.servlet` (`web.xml` version 2.5,
`javax.faces-2.2.20.jar`, Spring 5.3.39, Hibernate 5.5.9). Tomcat 10/11 use the
`jakarta.*` namespace. Tomcat 9.0.x is maintained until 2027-03-31, then a 9.1.x line
until 2030.

**JDK 17+ module flags:** `WEB-INF/bin/iiq` adds `--add-opens`/`--add-exports` itself;
**Tomcat inherits none of that.** They must be in `CATALINA_OPTS`. Minimum per Guide
p.6: `--add-exports=java.naming/com.sun.jndi.ldap=ALL-UNNAMED`.

### PostgreSQL

1. **No JDBC driver shipped** (Guide p.21). The WAR contains only
   `mysql-connector-j-8.4.0.jar`. The Dockerfile downloads `PG_JDBC_VERSION` (42.7.5).
2. **Quartz delegate is mandatory**, otherwise the scheduler fails:
   `scheduler.quartzProperties.org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.PostgreSQLDelegate`
3. **The DDL is a psql script, not plain SQL.** `create_identityiq_tables-8.5.postgresql`
   (9,146 lines) contains nine `\connect` meta-commands and itself creates three
   databases (`identityiq`, `identityiqah`, `identityiqPlugin`) and three roles with
   passwords. Consequences: run it through psql (the initdb hook), never set
   `POSTGRES_DB`, and `sed` the `CREATE USER … ENCRYPTED PASSWORD` lines at image build.
4. Hibernate dialect: `sailpoint.persistence.PostgreSQL10Dialect` (in `identityiq.jar`).
5. Case-insensitivity comes from 244 functional indexes on `upper(...)` — no special
   collation.
6. **The plugin database has 0 tables by design.** Plugins create their own.
7. **Tables live in a schema named like the database, not in `public`.** IIQ gets away
   with it because `"$user"` resolves to the same name as the schema. Every other
   client (`psql` as `postgres`, DBGate, ad-hoc SQL) needs the prefix or the
   `search_path` that `docker/postgres/02-search-path.sql` sets per role and database.
   `verify.sh` uses explicit prefixes so it does not depend on that hook having run on
   the current volume.
8. `include_dir` **cannot** be passed as `postgres -c include_dir=…` (`FATAL: unrecognized
   configuration parameter`). Tuning is appended to `postgresql.conf` by the initdb hook
   `00-apply-tuning.sh`. No `pg_ctl reload` there: `max_connections`/`shared_buffers`
   need a restart and the reload would log "configuration file contains errors" — the
   entrypoint restarts anyway.

### Sizes

| | |
|---|---|
| ZIP | 770 MB |
| `identityiq.war` | 742 MB |
| unpacked | ~1 GB, **8,984 files** |
| of which `WEB-INF/lib-connectors` | 562 MB, 15 bundles |

Hence multi-stage builds, a whitelist `.dockerignore`, the WAR deleted after unpacking,
and the ~1 GB `COPY` as the **last** layer in `docker/iiq/Dockerfile` so script edits
never invalidate it. `data/` is deliberately outside the build context — nothing copies
from it; a changed XML would otherwise re-trigger builds.

## Architecture decisions

**Init container.** `iiq-init` runs once and exits; `iiq` starts only after
`service_completed_successfully`. Keeps "initialize once" apart from "serve", and stays
correct with multiple IIQ nodes later.

**Idempotency via database state, not a marker file.** `entrypoint.sh` runs
`get Identity spadmin`. Reference project A uses a marker in a volume-mounted Tomcat
directory — which also makes image rebuilds a no-op there. DB state survives rebuilds,
restarts and volume swaps.

**Plaintext passwords, deliberately.** `iiq encrypt` binds values to the keystore
(`WEB-INF/classes/iiq.dat` + `iiq.cfg`). With the keystore inside the image that buys
nothing; reference project D even committed its keystore. For a dev box, plaintext from
`.env` is honest. Production would mount the keystore externally.

**`ImportAction name='merge'` instead of `sed`** for `SystemConfiguration` changes.
Patching `init.xml` (project A) is destructive and does not survive upgrades.

**Test data is generated from one person list.** `scripts/generate-testdata.py` emits
the HR CSV and both LDIFs. The LDAP seed accounts' `employeeNumber` **must** match a CSV
row or nothing correlates; two hand-maintained files would drift after the first edit.
Fixed `SEED` → identical data on every run → comparable IIQ test runs.

**Targets are nearly empty.** The HR CSV is the source of identities; LDAP, JDBC, SCIM
and the REST mock are targets where IIQ creates accounts. Each keeps a handful of seed
accounts so the correlation path is exercised too, not only the create path, and two or
three of them start disabled so the account *state* is aggregated as well: the LDAP
entry carries `pwdAccountLockedTime`, JDBC `Status=disabled` becomes `IIQDisabled` in
the BuildMap rule, SCIM `active=false` is mapped by the connector, the REST mock
exposes a boolean `disabled` mapped to `IIQDisabled` (the connector cannot derive it
from the `status` string). Groups and roles in the targets are complete — they are the
entitlements IIQ assigns.

**Ports bind to `127.0.0.1`.** Docker publishes on `0.0.0.0` by default; on a laptop in
a customer or hotel network the database would be reachable by everyone. The JDWP
debug port (8000) is an RCE vector if exposed — it is loopback-only via the override.
Inside the bridge network it necessarily listens on `0.0.0.0:8000`, so any sibling
container could attach a debugger; accepted for a dev stack, documented in the
override header.

**Cheap container hardening that costs nothing here:** `security_opt:
no-new-privileges` on every service; `cap_drop: [ALL]` on the three images we build
(uid 1000, ports > 1024). Not on postgres/openldap — their entrypoints chown and drop
privileges themselves. `ADD` of the JDBC driver carries `--checksum=sha256:…`
(cross-checked against Maven Central's `.sha1`); bumping `PG_JDBC_VERSION` means
updating the hash. Every third-party image is pinned by tag or digest; `dnknth/ldap-ui`
by digest because it is a personal namespace with mutable tags.

**Secrets never go to stdout.** The mock prints `Bearer token: set`, not the value —
`docker compose logs` ends up in log exports. (Reference project C `cat`s
`iiq.properties` into its log.)

**Compose override.** `docker-compose.override.yml` loads automatically and therefore
*is* the normal mode. Compose **merges lists** (`volumes`, `ports`) but **replaces
scalars** (`environment` entries). `CATALINA_OPTS` was once duplicated there and drifted
silently — an option only in the base file was never active. Now the base appends
`${IIQ_EXTRA_OPTS}` from `.env`; the override sets nothing else. Compose expands `${…}`
only from `.env`, not from another service's `environment` block.

## System landscape

| Object | Type | Role | Seed data |
|---|---|---|---|
| `HR-Application` | DelimitedFile, `authoritative="true"` | source | 100 people, `data/hr/HR-people.csv` |
| `LDAP-Target` | LDAPConnector | target | 8 accounts (3 disabled), 50 groups |
| `JDBC-Target` | JDBCConnector → `targetdb` in the same Postgres | target | 5 accounts (2 disabled), 6 roles |
| `SCIM-Target` | OpenConnectorAdapter / SCIM2Connector → `scim` container (own image) | target | 5 accounts (2 disabled), 6 groups |
| `WebService-Target` | WebServicesConnector → `mockapi` container | target | 6 accounts (2 disabled), 5 groups |

Correlation everywhere is `employeeNumber` (identity) = personnel number on the
account (`employeeNumber`, `IIQID`, `externalId`, `employeeId` respectively).

**Lifecycle.** `startDate`/`endDate` in the CSV → rule `HR Set Inactive` computes the
standard attribute `inactive` (start in the future or end reached → `true`) → two
`IdentityTrigger`s on the `inactive` transition start `HR Joiner Workflow` /
`HR Leaver Workflow`. The leaver builds a `Disable` plan for every non-authoritative
link; the joiner first `Enable`s links IIQ knows as disabled (returning person), then
`refreshIdentity` with provisioning creates whatever the roles require. Status in the
CSV is *derived* from the dates by the generator, never rolled independently —
otherwise rows contradict each other. Verified: 10 inactive = exactly 6 future joiners
+ 4 leavers. The workflows only run on a *transition* (see Pitfalls), so a fresh
database shows 0 runs; the live test in the README shows one each.

**Task order for a fresh database** (Setup → Tasks): HR Aggregation → LDAP Group
Aggregation → LDAP Account Aggregation → JDBC Aggregation → SCIM Group Aggregation →
SCIM Aggregation → WebService Group/Account Aggregation → Refresh Identity Cube. Groups
before accounts, or entitlements reference unknown groups and get no display name.

## Reference run

Measured on 2026-09-22 from `docker compose down -v` (fresh volumes, rebuilt images)
through the nine tasks and `verify.sh`; this is what a correct fresh setup looks
like. Anything else is a regression.

| Metric | Value | Why |
|---|---|---|
| identities | 105 | 100 HR + spadmin + 4 stock |
| with manager | 92 | every CSV row with `managerEmployeeNumber` |
| inactive | 10 | 6 future joiners + 4 leavers |
| open workflow cases / forms | 0 / 0 | no stuck provisioning |
| provisioning transactions | 322, all `Success` | 180 `IdentityIQ` role assignments; `Create` 82 LDAP, 24 JDBC, 16 SCIM, 9 REST; `Modify` 8 LDAP, 2 JDBC, 1 SCIM (seed accounts get their entitlements) |
| LDAP-Target links = directory entries | 90 | 8 seed + 82 created; 90 active people |
| JDBC / SCIM / WebService links | 29 / 21 / 15 | 5 + 24, 5 + 16, 6 + 9 (seed + role-driven creates) |
| disabled links LDAP / JDBC / SCIM / REST | 3 / 2 / 2 / 2 | the disabled seed accounts, state carried by each connector |
| roles | employee 90, it-staff 19, sales-staff 18, manager 18, operations-staff 17, finance-staff 11, hr-staff 9 | exact CSV counts |
| leaver / joiner workflow runs | 0 / 0 | triggers fire on transitions; see the lifecycle pitfall |

The three items that were open before this run — roles at 0, manager empty, the
Daniel Morgan merge — are closed; their root causes are recorded under Pitfalls
(`MatchExpression` OR default, `noManagerCorrelation`/`alwaysRefreshManager`, HR
correlation and naming). SCIM correlation was never broken: the seed users
correlate once the identities exist, i.e. after `HR Aggregation`.

Verified afterwards on the same database with the CSV edit from the README
(one active person, `endDate` yesterday): one `HR Leaver: <name>` run, the LDAP
entry gets `pwdAccountLockedTime: 000001010000Z`, the REST account
`status=DISABLED` (PATCH with a real body — the mock now rejects empty ones), the
links `iiqDisabled=true`; row restored: one `HR Joiner: <name>` run, the lock value
removed, REST `ACTIVE`, the links enabled, every provisioning transaction `Success`.
Role-driven creates on JDBC, SCIM (with group membership) and REST (with roles) are
part of the fresh run above.

## Pitfalls

### Docker, Compose, Windows

- **CRLF.** `.gitattributes` forces `eol=lf` on shell scripts *including* files without
  a `.sh` suffix (`entrypoint`, `healthcheck`, `console`). Otherwise
  `bad interpreter: No such file or directory`. Project B only covers `*.sh`.
- **`exec format error` with third-party images.** With the containerd image store
  Docker picks the **first** manifest entry, not the host arch. `axllent/mailpit` lists
  `linux/386` first, `dpage/pgadmin4` `arm64` first; `docker image inspect` still says
  `amd64`. Check with `docker manifest inspect <image> | grep '"architecture"'`; set
  `platform: linux/amd64`. pgAdmin failed even with that → replaced by DBGate. LDAP
  browser is `dnknth/ldap-ui` (amd64 first; phpLDAPadmin images are stale or arm-first;
  LLDAP is a server, not a browser). SCIM image has no version tags → pinned by digest.
- **YAML folded blocks have no comments.** In `CATALINA_OPTS: >-` a `#` line becomes part
  of the value and reaches the JVM: `Error: Could not find or load main class ssl`, then
  the full Java option help. Values containing spaces (`…pool.protocol=plain ssl`)
  cannot be passed in a folded block at all — unquoted the shell splits them, quoted the
  quotes become literals. That option is therefore not set; use `JAVA_TOOL_OPTIONS` if
  needed. Inspect the real value with `docker compose config | grep CATALINA_OPTS`.
- **Orphaned container names** after aborted runs: `docker compose up` says
  "name is already in use" but neither `docker rm <name>` nor `<id>` finds it. Try
  `docker compose down --remove-orphans` (no `-v`); if `docker ps` hangs, restart Docker
  Desktop — volumes and images survive. **Never `Stop-Process -Force` Docker Desktop**;
  that leaves a half-dead WSL VM ("Starting the Docker Engine…" at 0 % CPU forever).
  `wsl --shutdown`, then start normally.
- Moving the Docker data root (C: → E:) preserved images and volumes, including the
  initialized `iiq85_pgdata`. Displayed image sizes change afterwards (1.73 → 4.24 GB)
  because shared base layers are recounted; not real consumption.
- **`docker compose exec` under Git Bash** rewrites `/data/hr` into a Windows path
  (MSYS path conversion). Wrap container paths in `sh -c '…'` or set
  `MSYS_NO_PATHCONV=1`.
- **Certificate import was a silent no-op for the whole project history.** Temurin ships
  `$JAVA_HOME/lib/security/cacerts` as `root:root 0644`; the container runs as uid 1000,
  every `keytool -importcert` failed, stderr went to `/dev/null`, the log said
  "skipped". And it ran only in `iiq-init`, whose writable layer the `iiq` container
  never sees. Now: the Dockerfile chowns `cacerts` to 1000, the import runs in both
  containers, and only "already exists" is tolerated — any other keytool error fails
  the start. Test: drop a self-signed `.crt` into `data/certs/`, restart, expect
  `imported.` in the log.
- **`iiq "plugin install x.zip"` never worked.** The Launcher has no `plugin`
  application (`schema | extendedSchema | upgrade | patch | console | encrypt |
  integration | oim | exportschema`); every ZIP failed and `|| log` hid it. The console
  has `plugin install <path>`; the entrypoint now pipes that through
  `iiq_console_checked`.
- **`data/certs/` and `data/hr/` are gitignored except for the tracked seed CSV** —
  key material (`.key .p12 .pfx .jks`) or a real HR extract dropped there for a test
  must not reach `git add -A`.
- **`curl -w '%{http_code}'` prints the code even when curl exits non-zero.** With
  `--max-time` hit while the body was still streaming (JVM busy with two
  aggregations), `$(curl … || echo 000)` produced `HTTP 200000` and a false `[FAIL]`
  in `verify.sh`. Fall back to `000` only when nothing was printed.
- **Bash 5.2 treats `&` in `${var//pat/repl}` as "the match"** (`patsub_replacement`,
  on by default). `${f//\'/&apos;}` turned `'` into `'apos;`, and an unescaped `'`
  inside the pattern is a parse error at an unrelated line 100 lines later
  (`syntax error near unexpected token '('`). The manifest escaping uses `sed`.
  `bash -n` on every script before a rebuild — the init container is the only place
  that runs them and a parse error there blocks the whole stack.

### The IIQ console

- **`iiq console` does not exit on EOF.** `echo cmd | iiq console` hangs forever — first
  observed as 10 minutes at 43 % CPU with no output. Always append `quit`;
  `iiq_console()` in the entrypoint does.
- **Exit code is 0 on failure.** Stack traces go to stdout. `iiq_console_checked()`
  greps the output. The pattern is safety-critical: a false positive fails the init
  container and, via `service_completed_successfully`, **blocks the whole stack**.
  Current pattern, tested against both real failures and harmless output:
  ```
  ^Error:|^Caused by:|^[[:space:]]*at sailpoint\.|(java|javax|org|sailpoint|bsh)\.[A-Za-z.]*(Exception|Error)
  ```
  Catches `RuntimeException`, `SAXParseException`, `bsh.EvalError`, `GeneralException`,
  stack traces; passes `Unable to find localized message…`, `ExceptionHandler`, normal
  import lines. Anyone changing it re-tests both lists.
- **`run` needs quotes** around names with spaces. `run LDAP Group Aggregation` → tries a
  task named `LDAP` → "Ambiguous objects", exit code 0, nothing runs.
- **`run` returns immediately.** `quit` right after shuts the scheduler down and aborts
  the task ("The Scheduler has been shutdown"). Keep the console open until the task
  finishes; poll `spt_task_result.completion_status`. Do not trust sleep estimates —
  a refresh once ran *before* its aggregation because the sleep was too short; check
  timestamps.
- A task killed mid-run stays "running" in `spt_task_result` even after a container
  restart. `UPDATE spt_task_result SET completion_status='Terminated' WHERE
  completion_status IS NULL;` before re-running.
- `import init.xml` must precede `iiq patch`.
- **`source` is not a BeanShell runner.** It reads a file as console commands. For ad-hoc
  code, import a temporary `Rule` and `rule "name"` it; delete it afterwards.

### IIQ XML and the DTD

The DTD is generated at runtime by `sailpoint.tools.xml.DTDBuilder`; there is no file.
Dump it with `dtd /tmp/sp.dtd` in the console. Findings from 8.5:

- `ObjectAttribute` has **no `searchable`** — use `extendedNumber="n"` (columns
  `extended1…N`) or `namedColumn="true"`. Without one, the value sits only in the XML
  blob and **no filter can see it**: selectors and `managerCorrelationFilter` fail
  silently.
- `AttributeSource` allows only `ApplicationRef|RuleRef`. The source attribute name goes
  into `name=`.
- A rule-based `AttributeSource` **needs an `ApplicationRef`** too. With `RuleRef` alone
  the rule is never invoked — `context.runRule()` returned `true` for a leaver while
  `Identity.inactive` stayed `false`. Production exports use the `AppRule: …` form.
- `IdentityTrigger` references its workflow via the **attribute** `handler` plus
  `HandlerParameters`; there is no `<Handler>` element. Types: `Create`, `Delete`,
  `AttributeChange`, `Rule`, `ManagerTransfer`, `NativeChange`, `Alert`, `RapidSetup`
  (capital R). Template: `get IdentityTrigger Leaver`.
- `TaskDefinition` type for a refresh is `Identity`, not `IdentityRefresh`. Group
  aggregation uses `sailpoint.task.ResourceIdentityScan` with
  `aggregationType=group`; `sailpoint.task.AccountGroupScan` no longer exists (task ends
  in `Error` with the class name as the only message).
- **Unknown task options are silently dropped.** `refreshAssignedRoles` does not exist
  in 8.5; the task reports Success. Valid names: `get TaskDefinition "Identity Refresh"`.
- **`checkDeleted` defaults to false.** Accounts deleted in the target stay as links
  forever, and a refresh will not recreate them because the role is "satisfied" by the
  stale link. Measured after a directory reset: 5 entries, aggregation Success, 90
  links, 0 creates. Every target account aggregation here sets it; the HR aggregation
  too (a row removed from the CSV must drop its link).
- Role type `organization` maps to `organizational`, which has
  `noAssignmentSelector="true"` and `noAutoAssignment="true"` — it cannot carry a
  selector and is never auto-assigned. Import accepts it anyway. Use `business`.
  Types: `get ObjectConfig Bundle`.
- `MatchTerm` needs `type="IdentityAttribute"`; without it the term is evaluated as an
  entitlement. And `negative="true" value=""` means "≠ empty string" — it also matches
  `null`. Measured: 10 leaver runs for 4 real leavers. Use a `TriggerRule` with
  `Util.isNotNullOrEmpty()` for "is set".
- `featuresString` must contain `MANAGER_LOOKUP` or `managerCorrelationFilter` is
  ignored. DelimitedFile UI exports omit it; LDAP exports include it.
- **Ordering:** import `ObjectConfig` *before* the first aggregation. An attribute made
  searchable later needs another aggregation run.
- **`MatchExpression` is OR unless `and="true"`.** `IdentitySelector$MatchExpression._and`
  defaults to false; IIQ's own config writes `<MatchExpression and="true">` wherever AND
  is meant. Measured: `it-staff` (department=IT AND hrStatus=active intended) matched
  **90 of 111** identities instead of 18, `sales-staff` 93. Every multi-term selector
  needs `and="true"`; an OR inside an AND is a `container="true" and="false"` term.
- **Standard identity attributes have no source unless you add one.** The stock
  `ObjectConfig:Identity` defines `firstname`, `lastname`, `email`, `displayName` with
  **no** `AttributeSource`. Mapping only custom attributes left all 111 HR identities
  with NULL names; every create policy derives `sn`/`givenName`/`cn` from them, `sn` is
  required, so the Provisioner opened **94 provisioning forms** for spadmin and created
  zero accounts — while every task reported Success. `IdentityRefreshExecutor` then
  skips identities with a pending case, which hides the problem on the next run too.
  Clean up with `delete WorkflowCase "<name>"` in the console (Terminator removes case,
  TaskResult and WorkItem).
- **`template="true"` hides a TaskDefinition from Setup > Tasks.** The list bean filters
  `template=false`; the objects exist and run from the console, but the UI shows
  nothing. Runnable tasks are `template="false"` with a `<Parent>` reference to the
  stock template (`Account Aggregation`, `Account Group Aggregation`,
  `Identity Refresh`).
- **`call:provisionProject` wants `project`, not `plan`.** Compile first:
  `call:compileProvisioningProject` with `plan` → `resultVariable="project"`, then
  provision with `project`. Passing `plan` throws "Missing argument: project" — unseen
  until the first identity actually needs provisioning.
- **An authoritative application needs a `CorrelationConfig` too.** Without one the
  aggregator matches on the identity *name*, and the name of a new identity is the
  account's display attribute. Two "Daniel Morgan" rows (1007, 1030) became one
  identity with two HR links: 100 links, 99 identities, every count one short and
  no error anywhere. Fix: `AccountCorrelationConfig` on `employeeNumber` plus an
  `IdentityCreation` rule that names identities `first.last` and appends the employee
  number on a clash. Element name inside `Application` is `AccountCorrelationConfig`,
  not `CorrelationConfig` (DTD); children of `Application` may appear in any order.
- **Lifecycle triggers fire on transitions, not on state.** On a fresh database the
  four leavers are created with `inactive=true` straight away (the attribute rule
  runs during aggregation), so `Refresh Identity Cube` starts **0** leaver workflows;
  the "4 leaver runs" measured earlier came from a database where the rule had not
  run at aggregation time. To see the leaver: change a row's `endDate`/`status` in
  the live CSV, run `HR Aggregation`, then the refresh — one workflow, accounts
  disabled. Undo the row and repeat: one joiner, accounts enabled.
- **Every refresh with provisioning logs one `Modify` transaction per account, even
  when nothing changes.** The plan compiler filters the role entitlements the link
  already has (`FilterReason Exists`); the remaining `AccountRequest` carries no
  `AttributeRequest`, nothing reaches the connector, the transaction is still
  recorded as `committed`. Measured: +90 LDAP, +26 JDBC, +17 SCIM, +9 REST, +90
  `IdentityIQ` per `Refresh Identity Cube` on an unchanged database, all `Success`.
  Growth in `spt_provisioning_transaction` is therefore not a regression signal;
  a non-`Success` status or a real `AttributeRequest` in the `request` entry is.
- **Task results are replaced, not appended.** `resultAction` defaults to `Delete`; a
  second `run` of a task drops the earlier `spt_task_result` row and creates a new
  one. Polling "row exists" is therefore not enough for a re-run — compare `created`
  against a timestamp taken before the `run`.
- **XML comments must not contain `--`.** Use `=====` for rules, never `-----`.
- `entry` is `((key)?,(value)?)` — a CDATA body goes into `<value><String>`.

**The recurring signature — silent misconfiguration.** Six of the above share it: the
object imports and saves cleanly, `get` shows the value, nothing is evaluated, nothing
is logged. Inspecting the stored object proves only that the value is *there*. The only
reliable check is expected vs. actual: run the rule/filter in isolation and compare with
the resulting attribute.

### BeanShell

- **Unbound arguments are `void`, not `null`.** `if (link != null)` throws
  `bsh.EvalError: … undefined variable or class name: link`. Normalize first:
  ```java
  Link hrLink = null;
  if (link != void && link != null) hrLink = link;
  ```
  Applies to `link`, `result`, `accountRequest`, `oldValue` — the same rule runs from
  aggregation (bound) and from refresh without an account (unbound). Cost when missed:
  every identity failed, the aggregation ended in `Error`, and the database held **185
  identities instead of 102** — each failed row spawned one.
- **Cleanup goes through `sailpoint.api.Terminator`.** `DELETE FROM spt_identity` hits
  foreign keys (`spt_identity_capabilities`).
- **Check signatures by reflection, not JavaDoc.** The JavaDoc lists only `toString()`
  for `Link`; getters are inherited. Verified in 8.5: `Link.getAttribute(String)` exists,
  **`Link.getStringAttribute()` does not** (only `Identity` has it),
  `ProvisioningResult.addError(String|Message|Throwable)`, `STATUS_*` =
  `queued|committed|failed|retry`, `Schema.getAttributeDefinition(String)`,
  `JDBCConnector.buildMapFromResultSet(ResultSet, Schema)`.
- `Message` constructors are varargs; BeanShell does not synthesize the empty array.
  `new Message(type, text)` fails; `new Message(type, text, null)` works.

### Connectors

**LDAP.** `groupOfNames` requires at least one `member` (RFC 4519); an empty group aborts
the **entire** LDIF import with no error line — symptom: 5 accounts, 0 groups. Empty
groups get `cn=placeholder,dc=example,dc=com` as sole member; it lives outside
`ou=people` so account aggregation never sees it. `groupOfMembers` (optional `member`)
is not available in the Bitnami image. The group schema's `nativeObjectType` and
`groupMemberAttribute` must match the directory (`groupOfNames`/`member` here); a
production export used `groupOfUniqueNames`/`uniqueMember` and would aggregate nothing.
LDIFs load **only into an empty volume**: `docker compose rm -sf openldap &&
docker volume rm iiq85_ldapdata && docker compose up -d openldap`.
**Aggregation derives `IIQDisabled` from `revokeAttr`/`revokeVal`**: an entry seeded
with `pwdAccountLockedTime: 000001010000Z` (an operational attribute, but `ldapadd`
as the admin accepts it) arrives as a disabled link; the three disabled LDAP seed
accounts rely on that.
**Disable and Enable need three application entries each, plus the ppolicy
overlay.** `ENABLE` in `featuresString` only advertises the operations; without
`revokeAttr` the connector throws `No revoke attribute specified. Operation not
allowed`, without `restoreAttr` the mirror image `No restore attribute is
specified` — the workflow finishes "Success" either way and only the provisioning
transaction shows the failure. Measured twice: the leaver with the revoke entries
only, then the joiner with no restore entries. Settings (UI section "Enable Disable
Configuration", form `config/connector/LDAP.xml`): `revokeAttr=pwdAccountLockedTime`,
`revokeVal=000001010000Z`, `revokeAction=replace`; `restoreAttr` and `restoreVal`
identical, `restoreAction=remove`. Action semantics in `disableObject()` and
`enableObject()` are the same: `add` → Add, `replace` → Set (Remove when the value
is empty), anything else → Remove of that value. The attribute exists only with the
ppolicy overlay
(`LDAP_CONFIGURE_PPOLICY=yes` on the Bitnami image, config written at first init →
fresh volume); without it: `attribute type undefined`. Verify the key names against
the connector, not the UI labels: `jar tf lib-connectors/*.jar | grep LDAPConnector`,
`javap -c -p -constants` — the message catalog is not on the classpath in an
unpacked WAR.

**JDBC.** Fourth database in the same Postgres (`targetdb`, schema `targetapp`). Mixed-
case column names are deliberate — Postgres folds unquoted identifiers, so every
statement must quote them; a realistic porting trap. Five `JDBCProvision` rules plus a
`JDBCBuildMap` rule because roles live in a join table; the built-in SQL path cannot do
that. Status values are `active`/`disabled`, a contract between the DDL, the rules,
the application and the generator.
**The identity attribute is not in the create plan's attribute requests.** The
Provisioner moves the value of the schema's `identityAttribute` (`IIQID`) out of the
`AttributeRequest`s into `AccountRequest.nativeIdentity`, even though the create policy
sets it as a field. A create rule that reads it from the attribute map fails for
every role-driven create — measured: 29 `IIQID missing` failures, each request
carrying `nativeIdentity="10xx"`. Read `request.getNativeIdentity()` first.

**SCIM 2.0.** `authType="oauthBearer"` for a static token. `oauth2` maps to
`OAuth2Login` (full token flow) and yields `401 invalidCredentials`. Constants:
`javap -p -constants openconnector/connector/scim2/SCIM2Constants.class`.
`Class.forName("openconnector.connector.scim2.SCIM2Connector")` throws
`ClassNotFoundException` although the class is in `connector-bundle-webservices.jar` —
`OpenConnectorAdapter` uses its own class loader. `connectorDebug "<app>" test`,
`iterate` and `iterate group` are the reliable checks; they print the ResourceObjects
exactly as the aggregator sees them.
- **The entitlement attribute must be named `groups`, not `groups.value`.** The
  connector maps the schema name `groups` to the JSON path `groups[*].value`
  (`SCIM2Constants.JSON_PATH_GROUPS`); any other name is requested from the server
  but never mapped. Measured: with `groups.value` the aggregation was `Success` and
  the link had no entitlement at all; `iterate` shows `groups` as a list of ids
  after the rename. Nested single values (`name.givenName`) work with the dotted
  name; the multi-valued `emails.value` is not mapped either and stays empty —
  irrelevant here, correlation runs on `externalId`.
- **Renaming an entitlement attribute strands its `ManagedAttribute`s.** They keep
  the old `attribute` value, the next group aggregation tries to insert the same
  values under the new name and fails with `duplicate key value violates unique
  constraint uk_…` for every group (task result `Error`). Delete the old ones with
  `Terminator` from a temporary rule, then aggregate again.
- **`skipGrpUpdate` must be `false`.** An 8.5 UI export carries `true`; the
  connector then skips `modifyGroups()` (PATCH `/Groups/{id}` members) entirely
  and role-driven group assignments never reach the server.
- **The server must derive `groups` on the User.** The third-party server used
  first (`harrykodden/scim`) keeps membership only on the Group; the connector
  reads account entitlements only from the User's `groups`. Measured: group PATCH
  200, group aggregation creates the `ManagedAttribute`, account aggregation finds
  zero entitlements. Replaced by `docker/scim/app.py`, which computes `groups`
  from `Groups.members` on every read (RFC 7643 §4.1.2).

**Web Services.** Reference is `WEB-INF/config/connector/WebServices.xml` (the UI form
definition). `authenticationMethod`: `BasicLogin | OAuthLogin | OAuth2Login | No Auth`.
`operationType`: `Test Connection | Account Aggregation | Account Delta Aggregation |
Group Aggregation | Get Object | Get Object-Group | Create Account | Update Account |
Delete Account | Enable Account | Disable Account`. Traps, each found by starting from a
minimal application that worked and adding one thing at a time:
- `responseCode` entries must be `<Integer>`; `<String>` → `ClassCastException`.
- **The body text lives under `jsonBody`, whatever the format.** `bodyFormat` is
  `raw` or `formData` (form `config/connector/WebServices.xml`, fields `jsonBody` and
  `bodyFormData`); there is no `rawBody`. A `rawBody` entry is ignored without a
  message and the request goes out with `payload=null` — visible only with
  `logger.<x>.name=sailpoint.connector.webservices` at `trace` in
  `log4j2.properties`. Measured: every role-driven create answered `Missing required
  field: login` while the plan carried `login`; the leaver's Disable was "Success"
  because the mock accepted an empty PATCH with 200 (it rejects that now).
  `bodyFormat=json` does not exist: it fails in `initInternal` with a bare
  `ConnectorException`.
- `rootPath` belongs on the endpoint map (UI menu "Response Information"), not inside
  `resMappingObj`.
- The account `resMappingObj` must map the schema's `identityAttribute` by its own name
  (`id` → `id`), not only `nativeIdentity`. Otherwise Success with 0 accounts. Group
  aggregation hid this because `name` is mapped anyway.
- `paginationSteps` is a URL fragment (a `textarea` in the form), not a keyword. The
  value `offset` is not recognized and the connector loops: **11,943 requests** before
  the task was killed. Omit paging for small data sets.
- **The `encrypted` attribute list must exist on the application.** Every UI export
  carries it; without it any endpoint that has a `jsonBody` fails before the first
  request: `maskSecretAttributeInBody()` does `encryptedList.add("password")` and
  `Util.csvToList(null)` returns an immutable empty list →
  `UnsupportedOperationException`, reported as a bare `ConnectorException` from
  `initInternal`. Measured; the trace log names `getSortedEndPointsForV2`. Any
  non-empty value works (`password,accesstoken,…`).
- **Turn on the connector trace to see requests.** Append
  `logger.ws.name=sailpoint.connector.webservices` / `logger.ws.level=trace` and
  `logger.c.name=connector` / `logger.c.level=debug` to `WEB-INF/classes/log4j2.properties`
  (a console run picks it up at start); the dump line
  `==> Dumping request for troubleshooting purposes` shows URL, headers and `payload`.
  Together with `LOG_BODIES=true` on the mock that settles every body question in one
  run instead of guessing.
- **The create response mapping must map the identity attribute by its own name**
  (`id` → `id`), the same rule as for aggregation. With `nativeIdentity` → `id` alone
  the connector parses the id, still logs (trace only) `Native identity is neither
  present in the plan nor in the response`, reports `committed` and skips the
  Add Entitlement calls that belong to the create. Measured: nine accounts created,
  none with a role; with the extra mapping: create 201, one `POST …/roles` per value.
- **Never put a multi-valued `$plan.x$` into a raw body.** The list is rendered as a
  JSON string inside a one-element array with double-escaped quotes
  (`["[\"a\",\"b\"]"]`), which is not valid JSON. Entitlements belong to the
  Add/Remove Entitlement endpoints; `createAccountWithEntReq` only moves them into the
  create map and produces exactly that output.
- **Entitlements are deltas.** IIQ's Modify sends Add/Remove of single values, never the
  full list. An `Update Account` body with `{"roles": $plan.roles$}` overwrites the
  list: adding one role wipes the others, removing one *assigns* it. Use the
  `Add Entitlement` / `Remove Entitlement` operation types; the mock exposes
  `POST /users/{id}/roles` and `DELETE /users/{id}/roles/{role}` for exactly that.

### Test data generator

- Roles-per-department floor: `max(MIN_PER_DEPARTMENT, …)` pushes small departments up,
  the rounding difference goes negative, and if dumped on `headcounts[0]` the largest
  department (Sales) went negative and was skipped silently: `--users 5` → 14 people,
  no Sales; `--users 16` → 16 people, no Sales. Now the shortfall is subtracted
  round-robin above the floor and `main()` rejects `--users < 16`.
- Privileged groups: restrict candidates **before** computing the target size, or the
  sensitive groups collapse to one or two members.
- Non-ASCII values must be base64 in LDIF (RFC 2849, `cn:: …`); `ldif_value()` handles
  it. Current data is ASCII; the function stays for extensions.

## Reference projects

Analyzed from `Other SailPoint IdentityIQ Docker Projekts als Reference/` (gitignored).

| | Strength | Worst flaw |
|---|---|---|
| **A** `docker-IdentityIQ` | patch/version handling, `iiq schema` fallback | init runs inside a mounted volume → rebuild is a no-op; `apt-get install mariadb-server` at runtime |
| **B** `iiq-docker-developer-days-2025` | DDL in the DB image, DB-based idempotency, `import_folder()` | compose builds nothing, README has no build command |
| **C** `sailpoint-iiq-docker` | init-container pattern, multi-DB, demo objects, Traefik sticky sessions | passwords `cat`ed to the log, Tomcat manager exposed |
| **D** `standalone-docker-sailpoint-iiq` | SSB pipeline, `iiq encrypt`, non-root, Apache hardening | Java 8, MySQL 5.7, keystore and private key committed, init only via `docker exec` |

Taken: architecture and dev loop from B, init container from C, security model from D,
patch handling from A, demo-object idea from C. Added, missing in all four: health
checks, pinned image tags, `set -euo pipefail`, loopback port binding.
