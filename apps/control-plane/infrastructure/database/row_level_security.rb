# frozen_string_literal: true

module Nexus
  module Database
    # Isolation layer (a) of INV-14: PostgreSQL Row-Level Security.
    #
    # This module is the bridge between the application's tenant context and the
    # database session variable that RLS policies read. It is deliberately tiny —
    # the actual enforcement lives in the database, which is the whole point:
    # layer (a) must keep working when the application layer has a bug.
    #
    # The policy shape (see db/policies/) is:
    #
    #   USING (organization_id = current_setting('nexus.organization_id', true)::uuid)
    #
    # `current_setting(..., true)` returns NULL when the variable is unset, and
    # `organization_id = NULL` is NULL, which is not TRUE — so an unset variable
    # denies every row. RLS therefore fails closed by construction rather than by
    # our remembering to set something.
    module RowLevelSecurity
      SETTING = "nexus.organization_id"

      class << self
        # Apply the current tenant context to this database session.
        #
        # SET LOCAL scopes the setting to the enclosing transaction, so a pooled
        # connection cannot leak one request's tenant into the next — the classic
        # and very quiet failure mode of connection-pooled RLS.
        def apply!(connection = ActiveRecord::Base.connection)
          org_id = Tenancy::Context.current&.fetch(:organization_id, nil)
          return clear!(connection) if org_id.nil?

          connection.execute(
            "SET LOCAL #{SETTING} = #{connection.quote(org_id)}"
          )
          org_id
        end

        def clear!(connection = ActiveRecord::Base.connection)
          connection.execute("SET LOCAL #{SETTING} = ''")
          nil
        end

        # What the database currently believes the tenant is.
        #
        # Used by the consistency check below and by the isolation suite. Reading
        # it back rather than trusting what we set is deliberate: a stale
        # placement cache or a mis-routed connection shows up here.
        def current(connection = ActiveRecord::Base.connection)
          value = connection.select_value("SELECT current_setting('#{SETTING}', true)")
          value.presence
        end

        # Guard against the routing bug that RLS alone cannot catch: the
        # application thinks it is serving tenant A, but the connection it holds
        # has tenant B's session variable (stale resolver cache, connection
        # returned to the pool mid-flight, a rogue SET).
        #
        # ADR-009 calls this out explicitly — the tenant resolver is
        # security-critical code, and this is its backstop.
        def verify_consistency!(connection = ActiveRecord::Base.connection)
          expected = Tenancy::Context.current&.fetch(:organization_id, nil)
          actual = current(connection)

          return true if expected.nil? && actual.nil?
          return true if expected.to_s == actual.to_s

          raise TenantMismatch,
                "session tenant (#{actual.inspect}) does not match request tenant (#{expected.inspect}). " \
                "Refusing to execute — this indicates a connection-routing defect, not a data problem."
        end

        # Is RLS actually capable of denying anything on this connection?
        #
        # Returns a reason string when it is NOT enforceable, nil when it is.
        # Separate from assert_enforceable! so callers can report rather than
        # raise (the boot check warns in development, the suite raises).
        def unenforceable_reason(connection = ActiveRecord::Base.connection)
          row = connection.select_one(<<~SQL.squish)
            SELECT rolsuper, rolbypassrls
            FROM pg_roles WHERE rolname = current_user
          SQL
          return "connected as an unknown role" if row.nil?

          if row["rolsuper"]
            "connected as a SUPERUSER (#{connection.select_value('SELECT current_user')}), " \
              "which bypasses Row-Level Security unconditionally"
          elsif row["rolbypassrls"]
            "connected as a role with BYPASSRLS"
          end
        end

        def enforceable?(connection = ActiveRecord::Base.connection)
          unenforceable_reason(connection).nil?
        end

        # Refuse to proceed when RLS cannot possibly deny.
        #
        # This exists because the failure it prevents is invisible: an isolation
        # test run on a superuser connection passes while proving nothing. A
        # green suite that cannot fail is worse than no suite, because it is
        # trusted. See db/roles.sql and docs/security/findings.md SEC-001.
        def assert_enforceable!(connection = ActiveRecord::Base.connection)
          reason = unenforceable_reason(connection)
          return true if reason.nil?

          raise NotEnforceable,
                "Row-Level Security cannot be enforced: #{reason}. " \
                "Any isolation assertion made on this connection is meaningless. " \
                "Connect as the least-privilege application role (see db/roles.sql)."
        end

        # Wrap a block in a transaction with the tenant applied for its duration.
        # This is the only sanctioned way to run tenant-scoped SQL.
        def with_tenant_session(connection = ActiveRecord::Base.connection)
          connection.transaction do
            apply!(connection)
            verify_consistency!(connection)
            yield
          end
        end
      end

      TenantMismatch = Class.new(StandardError)
      NotEnforceable = Class.new(StandardError)
    end
  end
end
