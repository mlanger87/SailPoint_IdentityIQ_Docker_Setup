-- ===========================================================================
-- Zielsystem-Datenbank fuer den JDBC-Connector
-- ===========================================================================
-- Eine vierte Datenbank im selben Postgres-Container. Bewusst kein eigener
-- Container: der JDBC-Treiber liegt bereits im IIQ-Image (er wird fuer IIQ
-- selbst gebraucht), und ein zweites Datenbanksystem haette hier keinen
-- Erkenntniswert.
--
-- Die Tabelle folgt dem Muster einer typischen Zielsystem-Tabelle, wie sie
-- ein JDBC-Connector anspricht: eine flache Struktur mit einem eindeutigen
-- Schluessel, den IIQ als identityAttribute verwendet.
--
-- Laeuft als initdb-Hook nach der IIQ-Schema-DDL (Praefix 03).
-- ===========================================================================

CREATE USER targetapp WITH ENCRYPTED PASSWORD 'targetapp';
CREATE DATABASE targetdb OWNER targetapp;

\connect targetdb

-- Eigenes Schema statt public - konsistent mit den IIQ-Datenbanken.
CREATE SCHEMA targetapp AUTHORIZATION targetapp;

SET search_path TO targetapp, public;

-- ---------------------------------------------------------------------------
-- Die Account-Tabelle
--
-- IIQID ist der Korrelationsschluessel und entspricht der employeeNumber
-- aus der HR-Quelle. Er ist als identityAttribute in der Application
-- hinterlegt - der Wert, ueber den IIQ einen Account wiedererkennt.
--
-- Die Spaltennamen sind bewusst gemischt geschrieben (IIQID, FirstName),
-- wie es in gewachsenen Zielsystemen ueblich ist. In PostgreSQL erzwingt
-- das Anfuehrungszeichen bei jedem Zugriff - ein realistischer
-- Stolperstein, den die Provisioning-Rules korrekt behandeln muessen.
-- ---------------------------------------------------------------------------
CREATE TABLE targetapp."IIQData" (
    "ID"             SERIAL PRIMARY KEY,
    "IIQID"          VARCHAR(64)  NOT NULL UNIQUE,
    "Account"        VARCHAR(64),
    "FirstName"      VARCHAR(128),
    "LastName"       VARCHAR(128),
    "Name"           VARCHAR(256),
    "Email"          VARCHAR(256),
    "Phone"          VARCHAR(64),
    "Position"       VARCHAR(128),
    "Department"     VARCHAR(128),
    "Costcenter"     VARCHAR(64),
    "Location"       VARCHAR(128),
    "EmploymentType" VARCHAR(64),
    "Status"         VARCHAR(32)  DEFAULT 'aktiv',
    "Created"        TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    "Modified"       TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- Berechtigungstabelle
--
-- Das Zielsystem kennt Rollen, die einem Account zugewiesen werden.
-- Sie werden in IIQ zu Entitlements.
-- ---------------------------------------------------------------------------
CREATE TABLE targetapp."IIQRoles" (
    "ID"          SERIAL PRIMARY KEY,
    "RoleName"    VARCHAR(64)  NOT NULL UNIQUE,
    "Description" VARCHAR(256)
);

CREATE TABLE targetapp."IIQAccountRoles" (
    "IIQID"    VARCHAR(64) NOT NULL,
    "RoleName" VARCHAR(64) NOT NULL,
    PRIMARY KEY ("IIQID", "RoleName")
);

-- ---------------------------------------------------------------------------
-- Testdaten: ein paar Rollen, aber nur wenige Accounts.
--
-- Wie beim LDAP ist dies ein ZIELSYSTEM - die Accounts legt IIQ an.
-- Die wenigen vorhandenen dienen dem Korrelationsfall.
-- ---------------------------------------------------------------------------
INSERT INTO targetapp."IIQRoles" ("RoleName", "Description") VALUES
    ('TARGET_READ',      'Lesezugriff auf die Anwendung'),
    ('TARGET_WRITE',     'Schreibzugriff auf die Anwendung'),
    ('TARGET_APPROVE',   'Freigabeberechtigung'),
    ('TARGET_REPORT',    'Auswertungen und Berichte'),
    ('TARGET_ADMIN',     'Administration der Anwendung'),
    ('TARGET_AUDIT',     'Einsicht in das Protokoll');

-- Drei Bestandsaccounts. Die IIQID entspricht der employeeNumber von
-- Personen, die auch in der HR-CSV stehen - die Korrelation greift also.
INSERT INTO targetapp."IIQData"
    ("IIQID", "Account", "FirstName", "LastName", "Name", "Email",
     "Position", "Department", "Costcenter", "Location", "EmploymentType", "Status")
VALUES
    ('1001', 'udavis',  'Ursula', 'Davis',   'Ursula Davis',
     'ursula.davis@example.com',  'Director',    'Sales', 'CC-1000', 'London', 'employee', 'aktiv'),
    ('1030', 'vrussell','Vincent','Russell', 'Vincent Russell',
     'vincent.russell@example.com','Solution Architect','IT','CC-2000','London','employee','aktiv'),
    ('1070', 'sturner', 'Sandra', 'Turner',  'Sandra Turner',
     'sandra.turner@example.com', 'Analyst',     'Finance','CC-4000','London','employee','aktiv');

INSERT INTO targetapp."IIQAccountRoles" ("IIQID", "RoleName") VALUES
    ('1001', 'TARGET_READ'),
    ('1001', 'TARGET_APPROVE'),
    ('1001', 'TARGET_REPORT'),
    ('1030', 'TARGET_READ'),
    ('1030', 'TARGET_WRITE'),
    ('1030', 'TARGET_ADMIN'),
    ('1070', 'TARGET_READ'),
    ('1070', 'TARGET_REPORT');

-- Rechte fuer den Anwendungsbenutzer.
GRANT ALL PRIVILEGES ON SCHEMA targetapp TO targetapp;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA targetapp TO targetapp;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA targetapp TO targetapp;

-- Suchpfad dauerhaft setzen, damit Abfragen ohne Schema-Praefix
-- funktionieren - dieselbe Ueberlegung wie in 02-search-path.sql.
ALTER ROLE targetapp IN DATABASE targetdb SET search_path TO targetapp, public;
ALTER ROLE postgres  IN DATABASE targetdb SET search_path TO targetapp, public;
