-- ===========================================================================
-- Target-system database for the JDBC connector
-- ===========================================================================
-- A fourth database in the same Postgres container. Deliberately no
-- separate container: the JDBC driver is already in the IIQ image (IIQ
-- itself needs it), and a second DBMS would add nothing here.
--
-- The table follows the pattern of a typical target-system table as
-- addressed by a JDBC connector: a flat structure with a unique key that
-- IIQ uses as identityAttribute.
--
-- Runs as an initdb hook after the IIQ schema DDL (prefix 03).
-- ===========================================================================

CREATE USER targetapp WITH ENCRYPTED PASSWORD 'targetapp';
CREATE DATABASE targetdb OWNER targetapp;

\connect targetdb

-- Own schema instead of public - consistent with the IIQ databases.
CREATE SCHEMA targetapp AUTHORIZATION targetapp;

SET search_path TO targetapp, public;

-- ---------------------------------------------------------------------------
-- The account table
--
-- IIQID is the correlation key and equals the employeeNumber from the HR
-- source. It is configured as identityAttribute in the Application - the
-- value by which IIQ recognizes an account.
--
-- Column names are deliberately mixed-case (IIQID, FirstName), as is
-- common in grown target systems. In PostgreSQL this forces quoting on
-- every access - a realistic pitfall the provisioning rules must handle
-- correctly.
--
-- Status values 'active'/'disabled' are a data contract with
-- data/objects/26-Rules-JDBC.xml, 27-Application-JDBC.xml and
-- scripts/generate-testdata.py - change all four together.
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
    "Status"         VARCHAR(32)  DEFAULT 'active',
    "Created"        TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    "Modified"       TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------------
-- Entitlement tables
--
-- The target system has roles that are assigned to an account. They
-- become entitlements in IIQ.
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
-- Role catalog. Static, like the LDAP groups: these are the entitlements
-- IIQ can assign. Accounts are seeded separately (04-targetdb-seed.sql).
-- ---------------------------------------------------------------------------
INSERT INTO targetapp."IIQRoles" ("RoleName", "Description") VALUES
    ('TARGET_READ',      'Read access to the application'),
    ('TARGET_WRITE',     'Write access to the application'),
    ('TARGET_APPROVE',   'Approval permission'),
    ('TARGET_REPORT',    'Reports and analytics'),
    ('TARGET_ADMIN',     'Application administration'),
    ('TARGET_AUDIT',     'Audit log access');

-- Seed accounts and their role assignments are GENERATED into
-- 04-targetdb-seed.sql by scripts/generate-testdata.py, from the same
-- person list as the HR CSV and the LDAP seeds. Keeping them here by
-- hand let them drift (1030 was "Vincent Russell" here and
-- "Daniel Morgan" in the CSV).

-- Privileges for the application user.
GRANT ALL PRIVILEGES ON SCHEMA targetapp TO targetapp;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA targetapp TO targetapp;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA targetapp TO targetapp;

-- Persist the search path so queries work without a schema prefix -
-- same reasoning as in 02-search-path.sql.
ALTER ROLE targetapp IN DATABASE targetdb SET search_path TO targetapp, public;
ALTER ROLE postgres  IN DATABASE targetdb SET search_path TO targetapp, public;
