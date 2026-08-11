# frozen_string_literal: true

# Phase 3 — Row-Level Security. Isolation layer (a) of INV-14.
#
# This is the layer that keeps working when the application layer has a bug, so
# it is worth understanding exactly why each clause is there.
#
#   ENABLE ROW LEVEL SECURITY
#     Turns policies on. On its own this does NOT apply to the table's owner —
#     which in most deployments is the user that ran the migrations.
#
#   FORCE ROW LEVEL SECURITY
#     Applies policies to the owner too. Without this, RLS is silently inert for
#     any connection using the owning role, and the isolation test would pass for
#     the wrong reason. (Superusers still bypass RLS — which is why no
#     application role is ever a superuser.)
#
#   NULLIF(current_setting('nexus.organization_id', true), '')::uuid
#     `current_setting(…, true)` returns NULL rather than raising when the
#     variable was never set. NULLIF turns the explicit "cleared" value ('')
#     into NULL as well — otherwise ''::uuid raises 22P02 and the failure looks
#     like a type error instead of a denial.
#
#     Either way the comparison yields NULL, which is not TRUE, so no rows match.
#     RLS therefore FAILS CLOSED by construction, not by our remembering to set
#     something.
#
#   WITH CHECK
#     Same predicate applied to INSERT/UPDATE, so a cross-tenant *write* is
#     rejected too. USING alone would let one tenant insert rows attributed to
#     another and simply not be able to read them back.
#
# See: ADR-009, docs/08-security/tenant-isolation.md
class EnableRowLevelSecurity < ActiveRecord::Migration[7.1]
  # Tables keyed by their own `organization_id`.
  TENANT_TABLES = %w[
    service_identities
    sessions
    memberships
    teams
    team_memberships
    org_placements
    roles
    role_permissions
    grants
    policies
  ].freeze

  # `organizations` IS the tenant, so its policy keys on `id`, not on a
  # self-referential organization_id column.
  ROOT_TABLE = "organizations"

  TENANT_EXPR = "NULLIF(current_setting('nexus.organization_id', true), '')::uuid"

  def up
    TENANT_TABLES.each do |table|
      execute <<~SQL.squish
        ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
      SQL
      execute <<~SQL.squish
        ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
      SQL
      execute <<~SQL
        CREATE POLICY #{table}_tenant_isolation ON #{table}
          USING (organization_id = #{TENANT_EXPR})
          WITH CHECK (organization_id = #{TENANT_EXPR});
      SQL
    end

    execute "ALTER TABLE #{ROOT_TABLE} ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE #{ROOT_TABLE} FORCE ROW LEVEL SECURITY;"
    execute <<~SQL
      CREATE POLICY #{ROOT_TABLE}_tenant_isolation ON #{ROOT_TABLE}
        USING (id = #{TENANT_EXPR})
        WITH CHECK (id = #{TENANT_EXPR});
    SQL

    # Provisioning a new organization necessarily happens before that
    # organization's tenant context can exist. Rather than punching a hole in the
    # policy, provisioning runs as a dedicated role that is explicitly exempt.
    #
    # BYPASSRLS would be the blunt instrument; a named policy keeps the exemption
    # visible in \d+ output and reviewable in this file.
    execute <<~SQL
      CREATE POLICY #{ROOT_TABLE}_provisioning ON #{ROOT_TABLE}
        FOR INSERT
        WITH CHECK (current_setting('nexus.provisioning', true) = 'on');
    SQL

    # `users` is deliberately NOT tenant-scoped: a person may belong to several
    # organizations, and duplicating accounts per tenant breaks SSO identity and
    # makes "who is this human" unanswerable. Access to a user is mediated by
    # `memberships`, which IS tenant-scoped and RLS-protected.
    #
    # Recording this here because a future reader will otherwise assume it is an
    # oversight and "fix" it.
    say "users and permissions are intentionally global; access is mediated by memberships (see comment)"
  end

  def down
    (TENANT_TABLES + [ROOT_TABLE]).each do |table|
      execute "DROP POLICY IF EXISTS #{table}_tenant_isolation ON #{table};"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY;"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY;"
    end
    execute "DROP POLICY IF EXISTS #{ROOT_TABLE}_provisioning ON #{ROOT_TABLE};"
  end
end
