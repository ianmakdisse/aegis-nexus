-- Database roles — ADR-009 / INV-14 layer (a).
--
-- WHY THIS FILE EXISTS
--
-- Row-Level Security is silently inert for:
--   * a SUPERUSER               (bypasses RLS unconditionally)
--   * a role with BYPASSRLS
--   * the table OWNER           (unless FORCE ROW LEVEL SECURITY is set — we set it)
--
-- The first case is the dangerous one, because local development and CI commonly
-- run as a superuser. An isolation test executed on a superuser connection
-- PASSES WHILE PROVING NOTHING: every row is visible, the assertion "tenant B
-- cannot see tenant A" is never actually exercised, and the suite stays green
-- for as long as it takes for someone to trust it.
--
-- This was not hypothetical. It happened on the first run of this project's
-- isolation check (see docs/security/findings.md SEC-001), which is why
-- Nexus::Database::RowLevelSecurity.assert_enforceable! now refuses to run the
-- suite on a connection that can bypass policy.
--
-- Roles:
--   nexus_owner  — owns the schema, runs migrations. DDL. Never serves requests.
--   nexus_app    — what every request-serving process uses. DML only, RLS applies.
--   nexus_ro     — read-only, for analytics/support tooling. RLS applies.
--
-- Apply with:  psql -d <database> -f db/roles.sql

\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nexus_app') THEN
    CREATE ROLE nexus_app LOGIN PASSWORD 'nexus_app';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nexus_ro') THEN
    CREATE ROLE nexus_ro LOGIN PASSWORD 'nexus_ro';
  END IF;
END
$$;

-- Explicitly strip the attributes that would void RLS. Belt and braces: these
-- roles are created without them, but an operator "temporarily" granting
-- superuser to debug is exactly how isolation quietly stops being enforced.
ALTER ROLE nexus_app NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
ALTER ROLE nexus_ro  NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;

-- :"DBNAME" is psql's built-in for the connected database. `CURRENT_CATALOG` is
-- not accepted here, and because this script runs with ON_ERROR_STOP, getting it
-- wrong silently skips every GRANT below it — which presents later as an
-- inexplicable "permission denied for table organizations".
GRANT CONNECT ON DATABASE :"DBNAME" TO nexus_app, nexus_ro;
GRANT USAGE ON SCHEMA public TO nexus_app, nexus_ro;

-- DML only. No DDL: the application must not be able to alter a table, drop a
-- policy, or disable RLS on itself.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nexus_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO nexus_ro;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO nexus_app;

-- Future tables created by migrations inherit the same grants, so adding a table
-- never silently leaves the app role without access (or, worse, prompts someone
-- to run the app as owner to "fix" it).
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO nexus_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO nexus_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO nexus_app;
