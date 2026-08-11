# frozen_string_literal: true

module Nexus
  module Migration
    # Row-level security for a tenant table, as one call.
    #
    # Phase 3 enabled RLS on eleven tables with a hand-written loop. That worked,
    # and it also meant the correctness of isolation layer (a) depended on
    # somebody remembering to add each new table to a list in an old migration.
    # `migration-lint` now fails a build that creates a tenant table without a
    # policy, and this helper is what that rule expects you to call — a check
    # that tells you what to do is worth more than one that only says no.
    #
    # Each clause matters; the long form and the reasoning are in
    # db/migrate/20260810000003_enable_row_level_security.rb.
    module Tenancy
      TENANT_PREDICATE = "NULLIF(current_setting('nexus.organization_id', true), '')::uuid"

      # @param table [Symbol, String]
      # @param column [Symbol] the tenant key — `:id` for the organizations table
      #   itself, which IS the tenant rather than belonging to one
      def enable_tenant_rls!(table, column: :organization_id)
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;"

        # Without FORCE, policies do not apply to the table's owner — which is
        # the role that ran the migration. RLS would be silently inert, and the
        # isolation suite would pass for the wrong reason (see SEC-001).
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;"

        execute <<~SQL
          CREATE POLICY #{table}_tenant_isolation ON #{table}
            USING (#{column} = #{TENANT_PREDICATE})
            WITH CHECK (#{column} = #{TENANT_PREDICATE});
        SQL
      end

      def disable_tenant_rls!(table)
        execute "DROP POLICY IF EXISTS #{table}_tenant_isolation ON #{table};"
        execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY;"
        execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY;"
      end
    end
  end
end
