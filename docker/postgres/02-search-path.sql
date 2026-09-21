-- ===========================================================================
-- search_path auf die IIQ-Schemata setzen
-- ---------------------------------------------------------------------------
-- Die SailPoint-DDL legt die Tabellen NICHT in "public" ab, sondern in ein
-- gleichnamiges Schema (identityiq bzw. identityiqah). Der PostgreSQL-Default
-- fuer search_path ist aber "$user", public.
--
-- Fuer IdentityIQ selbst geht das gerade noch gut, weil sich "$user" zum
-- Benutzernamen aufloest und dieser zufaellig genauso heisst wie das Schema.
-- Fuer alle anderen Zugriffe - Adminer, psql als postgres, eigene
-- Auswertungen - ist das Schema dagegen nicht im Suchpfad:
--
--     SELECT * FROM spt_identity;          -- relation does not exist
--     SELECT * FROM identityiq.spt_identity;  -- funktioniert
--
-- Das ist unnoetig unbequem. Deshalb wird der Suchpfad hier dauerhaft pro
-- Rolle und Datenbank gesetzt.
--
-- Laeuft als initdb-Hook NACH der Schema-DDL (Praefix 02).
-- ===========================================================================

-- Hauptdatenbank
ALTER ROLE identityiq IN DATABASE identityiq SET search_path TO identityiq, public;
ALTER ROLE postgres   IN DATABASE identityiq SET search_path TO identityiq, public;

-- Access History
\connect identityiqah
ALTER ROLE identityiqah IN DATABASE identityiqah SET search_path TO identityiqah, public;
ALTER ROLE postgres     IN DATABASE identityiqah SET search_path TO identityiqah, public;

-- Plugin-Datenbank
-- Hier liegen zunaechst keine Tabellen; die legt jedes Plugin bei seiner
-- Installation selbst an. Der Suchpfad wird trotzdem vorbereitet.
\connect "identityiqPlugin"
ALTER ROLE "identityiqPlugin" IN DATABASE "identityiqPlugin" SET search_path TO "identityiqPlugin", public;
ALTER ROLE postgres           IN DATABASE "identityiqPlugin" SET search_path TO "identityiqPlugin", public;
