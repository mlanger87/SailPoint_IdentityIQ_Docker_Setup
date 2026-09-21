-- ===========================================================================
-- Set search_path to the IIQ schemas
-- ---------------------------------------------------------------------------
-- SailPoint's DDL does NOT put the tables into "public" but into a schema
-- of the same name (identityiq resp. identityiqah). PostgreSQL's default
-- search_path, however, is "$user", public.
--
-- For IdentityIQ itself this just about works, because "$user" resolves
-- to the user name, which happens to equal the schema name. For every
-- other access - DBGate, psql as postgres, ad-hoc queries - the schema is
-- not on the search path:
--
--     SELECT * FROM spt_identity;          -- relation does not exist
--     SELECT * FROM identityiq.spt_identity;  -- works
--
-- Needlessly inconvenient. So the search path is set persistently here
-- per role and database.
--
-- Runs as an initdb hook AFTER the schema DDL (prefix 02).
-- ===========================================================================

-- Main database
ALTER ROLE identityiq IN DATABASE identityiq SET search_path TO identityiq, public;
ALTER ROLE postgres   IN DATABASE identityiq SET search_path TO identityiq, public;

-- Access History
\connect identityiqah
ALTER ROLE identityiqah IN DATABASE identityiqah SET search_path TO identityiqah, public;
ALTER ROLE postgres     IN DATABASE identityiqah SET search_path TO identityiqah, public;

-- Plugin database
-- No tables here initially; each plugin creates its own on installation.
-- The search path is prepared regardless.
\connect "identityiqPlugin"
ALTER ROLE "identityiqPlugin" IN DATABASE "identityiqPlugin" SET search_path TO "identityiqPlugin", public;
ALTER ROLE postgres           IN DATABASE "identityiqPlugin" SET search_path TO "identityiqPlugin", public;
