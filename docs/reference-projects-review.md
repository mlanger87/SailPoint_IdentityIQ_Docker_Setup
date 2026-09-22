# Reference projects: what they do that this setup does not

Review of the four public IIQ Docker projects that informed this setup, written before
they were deleted from the working copy (they were never part of the repository; see
the "Reference projects" table in `CLAUDE.md` for the one-line verdicts). This file
records what remains worth taking, so the deletion loses nothing.

Verdict per item: **yes** = worth adopting for a local dev environment, **maybe** =
useful but optional or with a caveat, **no** = do not copy. Paths are relative to the
respective project.

## A — `docker-IdentityIQ` (EpiicDream)

- **One-click task chain.** `TaskDefinition` type `Generic`, parent `Sequential Task
  Launcher`, `taskList` of task names, `exitOnError`
  (`identityiq-objects/Custom-TaskDefinitions.xml` 202–243). Our eight-task order lives
  in README prose only. **yes**, includes `Full Text Index Refresh`, which we never run.
- **`resultAction="Rename"` on every TaskDefinition** (same file). Keeps result history;
  we document the opposite pain ("results are replaced, not appended"). **yes**.
- **QuickLink + workflow pair to terminate/reactivate an identity from the UI**
  (`Custom-Quicklinks.xml`, `Custom-Workflows.xml` 6–50). Replaces the CSV-edit dance of
  our lifecycle demo. **yes**; the workflow bodies are stubs, ours would reuse
  `HR Leaver Workflow`.
- **`wfcase.getTaskResult().setName(...)`** for readable workflow result names
  (`Custom-Workflows.xml` 13–18). **yes** (tiny).
- **Create/Update Identity forms with dependent dropdowns** (`Custom-Forms.xml`).
  **maybe** — instructive for Form mechanics, but conflicts with the authoritative CSV.
- **AfterProvisioning rule that renames an LDAP entry via JNDI** (`Custom-Rules.xml`
  283–386). **maybe**; note it swallows `NamingException`.
- **`GroupAggregationRefresh` rule setting groups non-requestable** (same file, 134–181).
  **maybe**.
- **Role model generated from aggregated groups** (`Custom-Rules.xml` 185–280). **no** as
  a replacement (hand-written selectors are the point here), **maybe** as an additive
  scale demo.
- **Pre-wired `custom.*` log4j2 logger writing to a file** (`docker/tomcat/entrypoint.sh`
  22–31). We never touch `log4j2.properties`. **yes** — most-used dev facility in rule
  work.
- **Volume backup/restore scripts** (`volumes_backup.sh`, `volumes_restore.sh`, with the
  "same IIQ version only" caveat). **yes**.
- **Reset script that also drops the built image** (`reset_containers.sh`). **maybe**.
- **Custom-WAR / custom-keystore build switches**, including *skipping* the ObjectConfig
  import over an SSB WAR (`docker/tomcat/Dockerfile` 3–9, `entrypoint.sh`). **maybe**.
- **`iiq schema` when a custom WAR is supplied** (`entrypoint.sh` 41). We never run
  `schema`/`extendedSchema`. **yes** (see D).
- Tomcat manager with `admin/admin`; `apt-get install mariadb-server` at first start;
  marker file in a mounted Tomcat directory; `sed` on `init.xml`; `identity.setPassword("xyzzy")`
  in an IdentityCreation rule. **no** (see "Do not copy").

## B — `iiq-docker-developer-days-2025`

- **IIQ Dev Accelerator workflow** (`configuration/workflow.xml`, `IIQDevAcceleratorWF`):
  server-side import, list/get/delete objects, run task, run rule, `evalBS` (ad-hoc
  BeanShell with a context), read/hot-reload `log4j2.properties`, `importJava` (JDI
  hot-swap over the debug port), certificate import, restart. **yes, highest value** —
  removes our "import a temporary Rule and delete it" workaround; loopback-only, it is
  remote code execution by design.
- **`console` wrapper using `iiq console -j`** (`scripts/console`). **maybe** — check
  whether `-j` shortens console start-up.
- DDL baked into the DB image via a busybox stage; patch level from
  `WEB-INF/config/patch/*-README.txt`; `import_folder()` manifest; idempotency probe
  via `list workflow`; `URIEncoding` sed; mail settings via `ImportAction merge`.
  **already adopted** (ours adds sorting, escaping and error checks).
- 240-entry LDIF directory as source. **no** — our targets are nearly empty by design.
- Compose builds nothing, README has no build command. **no** (known flaw).

## C — `sailpoint-iiq-docker` (Identity Works)

- **`build.sh` staging CLI** (`-z` zip, `-w` war, `-b` SSB, repeatable `-p` patch, `-e`
  efix, `-m` plugin, `-c` cert, `-o` objects) with input validation. **maybe** — steal
  the validation and multi-patch/e-fix support, not the CLI.
- **E-fix JARs as first-class artefacts** (`iiq-build/entrypoint.sh` 161–165). **yes**.
- **Version/patch read from `identityiq.jar` `MANIFEST.MF`** (same file, 169–172) instead
  of trusting `.env`. **yes**.
- **All shipped `upgrade_identityiq_tables-*` scripts applied in sorted order**
  (`database-setup.*.sh`). **maybe**.
- **Plugin database created with grants parsed from `iiq.properties`**, shipped plugins
  DDL run if present. **maybe** — verify we run the Postgres plugins DDL if one exists.
- **Multi-node with a `counter` sidecar for `iiq.hostname`** plus **Traefik sticky
  sessions** (`docker-compose.yml` 4–6, 75–136). **maybe** — package deal, medium/large;
  Traefik mounts the Docker socket.
- ActiveMQ Artemis service. **no** for a laptop.
- **SSH server + `Linux - Direct` application** (`DemoObjects/Application-LinuxAccount.xml`).
  **maybe** — a fifth connector family, brittle.
- **Partitioned aggregation `RequestDefinition`**. **maybe**, not at our scale.
- **`PopulationRef` selector on a Bundle** (`DemoObjects/GroupDefinition-ItStaffPopulation.xml`,
  `Bundle-ItStaff.xml`). **yes (additive)** — sidesteps the `MatchExpression` OR default,
  supports LIKE/ANYWHERE.
- **`groupFactory="true"` on ObjectConfig attributes**; **`editMode="ReadOnly"` /
  `UntilFeedValueChanges`** on feed-sourced attributes (`DemoObjects/ObjectConfig-Identity.xml`).
  **maybe** / **yes**.
- **JDBC target with a `roles_permissions` table** for SoD demos; fake-SSN column for
  masking demos (`iiq-build/sql/target.sql`, `HRDATA.md`). **maybe**.
- **Hash-verified helper JAR download** (`iiq-build/fetch-package.sh`). **no** to the JAR,
  same discipline as our `ADD --checksum`.
- **OCI image labels**; **`ROOT/index.html` redirect to `/identityiq`**. **yes** (trivial).
- SERI/Accelerator-Pack auto-detection: adopted; per-use-case pusher `bin/seri.sh`
  **maybe**.
- `bin/*` helpers. **no** — `scripts/iiq.ps1` covers it.
- `cat`s `iiq.properties` into the log; Tomcat manager with `RemoteAddrValve allow="^.*$"`;
  runtime `apt-get install mysql-server`. **no**.

## D — `standalone-docker-sailpoint-iiq` (UberEther)

- **`iiq schema` + `iiq extendedSchema` in the build** (`ssb/components/ue-configuration/scripts/build.custom.ue-configuration.xml`,
  `post.expansion.hook`). We declare `extendedNumber` attributes and never regenerate
  the schema. **yes, highest-priority correctness check**: confirm the backing columns
  exist in the stock DDL, record the finding, add the step if not.
- **Time machine debug page** (`Configuration-core-enableTimeMachine.xml`,
  `timeMachineEnabled=true`). **yes** — our lifecycle is date-driven; "advance the
  clock" beats editing the CSV.
- **Session timeout 600 min for dev** (`web.xml` replaceregexp). **yes**.
- **`WEB-INF/bin/iiq` launcher heap raised to 2 GB** (same file). Every console run
  uses the stock 256 MB. **yes**.
- **Config export of ~75 classes before every import** (`iiq-loadXml.sh`,
  `BACKUP_CLASSES`). Makes "what did my import change" answerable. **yes**.
- **`plugin upgrade` instead of `plugin install`** (same script) — idempotent. **yes**,
  likely a live bug in our re-run path.
- md5sums of scripts and config logged before acting; `tee` transcript with an exit
  trap; timed build phases. **maybe**.
- **Apache HTTPD reverse proxy with TLS, AJP, `X-Forwarded-*`** (`ICAM-HTTPD/httpd.conf`).
  **maybe** — only to exercise proxy behaviour; their private key is committed.
- Hostname-based access via `/etc/hosts`. **maybe** (pairs with the proxy).
- **JMX endpoint, commented out** (`ICAM-TOMCAT/Dockerfile`). **maybe** as an opt-in.
- **LDAP pool `CATALINA_OPTS` with spaces set in the image**, not in compose. Closes a
  documented gap of ours. **yes**.
- **`TZ` pinned in every image.** Our containers run UTC against bare CSV dates.
  **yes** — prevents an off-by-one-day around midnight.
- Non-root user with `-s /bin/nologin` and setgid directories. **no**, ours is
  equivalent.
- Read-write bind mount of the whole webapp. **no** (image stops being the source of
  truth); prefer B's hot-swap.
- MySQL tuning with per-setting provenance comments; `.my.cnf` mode 600 so passwords
  never hit the command line. **maybe** (documentation style / `.pgpass`).
- SSB pipeline with per-environment config, `ignorefiles.properties`, token
  substitution. **maybe** — two transferable ideas, no local gain from Ant.
- Encrypted passwords with an externally mounted keystore (`keyStore.file`,
  `keyStore.passwordFile`). **no** to encrypting now, **yes** to knowing the properties.
- Connection-pool and `bsfManagerPool` tuning in `iiq.properties`. **maybe**.
- **Image slimming** (delete `tutorials/`, `integration/`, non-Linux `WEB-INF/bin/*`,
  non-Postgres DDL). **yes**.
- Git LFS for binaries; CHANGELOG with migration notes. **no** / **maybe**.

## Prioritised candidates

| # | Improvement | Effort | Source |
|---|---|---|---|
| 1 | Verify extended-attribute columns; add `iiq schema`/`extendedSchema` if needed | small–medium | D, A |
| 2 | Import the Dev Accelerator workflow; document the VS Code extension and the RCE caveat | medium | B |
| 3 | `Sequential Task Launcher` objects for the task chain; `resultAction="Rename"` | small | A |
| 4 | Dev-loop bundle: `TZ`, launcher heap, session timeout, LDAP pool opts in the image, `custom.*` logger, `/` redirect, OCI labels | small | D, A, C |
| 5 | `iiq.ps1 export` of the custom object classes, run before each init import | small | D |
| 6 | Time machine enabled; lifecycle demo via the clock | small | D |
| 7 | `plugin upgrade`; e-fix support; version/patch from the JAR manifest | small | D, C |
| 8 | Volume backup/restore scripts | small | A |
| 9 | Demo surface: `PopulationRef` selector, `groupFactory`, `editMode`, SoD policy on a permissions table | medium | C |
| 10 | Image slimming in the extract stage | small | D |

Below the cut: multi-node + Traefik (C), HTTPD/TLS proxy (D), SSH/Linux target (C), UI
identity forms (A), JMX profile (D), staging CLI (C), partitioning (C), SSB (D).

## Do not copy

- Runtime `apt-get install` of database servers or editors inside the app container (A, C).
- Initialisation state in a marker file inside a mounted Tomcat directory (A).
- Tomcat manager/host-manager exposed, with default credentials or `allow="^.*$"` (A, C).
- `cat` of `iiq.properties` into the container log (C).
- Committed private keys, certificates and IIQ keystores (D).
- Global `sed 's/localhost/…/'` on `iiq.properties`; in-place patching of `init.xml` (A).
- Unpinned `:latest` third-party images; `osixia/openldap` and `osixia/phpldapadmin` (A, B, C).
- Java 8 / MySQL 5.7 / IIQ 8.1 stacks (D).
- Read-write bind mount of the whole webapp (D).
- Docker socket mounted into a proxy container (C).
- LDAP group schema `groupOfUniqueNames` against a directory of `groupOfNames` entries (A).
- Shared literal password in an IdentityCreation rule or form default (A).
- `printStackTrace()` as error handling in rules (A).
