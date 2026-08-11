# frozen_string_literal: true

require "rails_helper"

# Tenant isolation — INV-14 / FR-102.
#
# The requirement is not "isolation works". It is that isolation is enforced at
# THREE INDEPENDENT layers, such that removing any one of them still denies:
#
#   (a) PostgreSQL Row-Level Security
#   (b) Application default scoping (TenantScopedRecord)
#   (c) Request/job-scoped tenant context (Nexus::Tenancy::Context)
#
# So this suite deliberately DISABLES layers to prove the remainder hold. A suite
# that only tested the happy path would pass with two of the three layers broken.
#
# Read docs/security/findings.md SEC-001 before changing the guard below.
RSpec.describe "Tenant isolation", :isolation, type: :model do
  # `let!`, not `let`, and deliberately so: lazy evaluation would provision a
  # tenant *inside* whichever `as_tenant` block first referenced it, which the
  # nested-context guard correctly rejects. Both tenants must exist before any
  # example enters a tenant context.
  #
  # (This was a real failure while writing the suite — the guard caught the test,
  # which is a reasonable advertisement for the guard.)
  let!(:acme_id)   { provision_organization!(name: "Acme",   slug: "acme-#{SecureRandom.hex(4)}") }
  let!(:globex_id) { provision_organization!(name: "Globex", slug: "globex-#{SecureRandom.hex(4)}") }

  # ---------------------------------------------------------------------------
  describe "the guard (SEC-001 regression)" do
    it "refuses to make isolation assertions on a connection that can bypass RLS" do
      # This is the finding that made the rest of this suite trustworthy: on a
      # superuser connection every assertion below would pass while proving
      # nothing, because superusers bypass RLS unconditionally.
      expect { Nexus::Database::RowLevelSecurity.assert_enforceable! }.not_to raise_error

      reason = Nexus::Database::RowLevelSecurity.unenforceable_reason
      expect(reason).to be_nil,
                        "RLS is not enforceable on this connection (#{reason}). " \
                        "Every example in this file would pass without testing anything. " \
                        "Connect as nexus_app — see db/roles.sql."
    end
  end

  # ---------------------------------------------------------------------------
  describe "all three layers active (production configuration)" do
    it "shows a tenant only its own organization" do
      acme_id
      globex_id

      as_tenant(acme_id) do
        visible = Nexus::Organizations::Internal::Models::Organization.pluck(:id)
        expect(visible).to eq([acme_id])
      end
    end

    it "does not leak another tenant's memberships" do
      user_id = create_user!(email: "u-#{SecureRandom.hex(4)}@test.local")

      as_tenant(acme_id) do
        Nexus::Organizations::Internal::Models::Membership.create!(user_id: user_id)
      end

      as_tenant(globex_id) do
        expect(Nexus::Organizations::Internal::Models::Membership.count).to eq(0)
      end
    end

    it "rejects a write attributed to another tenant" do
      user_id = create_user!(email: "u-#{SecureRandom.hex(4)}@test.local")

      as_tenant(acme_id) do
        record = Nexus::Organizations::Internal::Models::Membership.new(
          organization_id: globex_id, user_id: user_id
        )
        expect(record).not_to be_valid
        expect(record.errors[:organization_id].join).to match(/does not match the current tenant/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "layer (c) removed — no tenant context" do
    it "raises rather than returning an unscoped or empty result" do
      # Returning [] here would be 'safe' but would masquerade as 'no data',
      # sending the next engineer to look for a data bug instead of a scoping bug.
      expect { Nexus::Organizations::Internal::Models::Membership.count }
        .to raise_error(TenantScopedRecord::UnscopedQuery, /no tenant context/)
    end

    it "raises when tenant context is read directly" do
      expect { Nexus::Tenancy::Context.organization_id }
        .to raise_error(Nexus::Tenancy::Context::Missing, /INV-14 layer c/)
    end
  end

  # ---------------------------------------------------------------------------
  describe "layers (b) and (c) removed — only the database is left" do
    it "still denies cross-tenant reads via RLS alone" do
      user_id = create_user!(email: "u-#{SecureRandom.hex(4)}@test.local")
      as_tenant(acme_id) do
        Nexus::Organizations::Internal::Models::Membership.create!(user_id: user_id)
      end

      with_application_layers_disabled do
        # Layer (c) is off, and `unscoped` removes layer (b) entirely — exactly
        # what a hand-written query or a careless `unscoped` call would do.
        Nexus::Tenancy::Context.with(organization_id: globex_id) do
          Nexus::Database::RowLevelSecurity.apply!
          leaked = Nexus::Organizations::Internal::Models::Membership.unscoped.count
          expect(leaked).to eq(0), "RLS failed to contain a query that bypassed application scoping"
        ensure
          Nexus::Database::RowLevelSecurity.clear!
        end
      end
    end

    it "denies everything when no tenant is set in the database session" do
      acme_id

      with_application_layers_disabled do
        Nexus::Database::RowLevelSecurity.clear!
        count = Nexus::Organizations::Internal::Models::Organization.unscoped.count
        expect(count).to eq(0), "RLS must fail closed when the session variable is unset"
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "connection/context consistency (the routing-bug backstop)" do
    it "detects a session whose tenant disagrees with the request's tenant" do
      # Simulates a stale placement cache or a mis-routed pooled connection:
      # the app believes it is serving Acme, the connection says Globex.
      Nexus::Tenancy::Context.with(organization_id: acme_id) do
        ActiveRecord::Base.connection.execute(
          "SET LOCAL nexus.organization_id = #{ActiveRecord::Base.connection.quote(globex_id)}"
        )

        expect { Nexus::Database::RowLevelSecurity.verify_consistency! }
          .to raise_error(Nexus::Database::RowLevelSecurity::TenantMismatch, /connection-routing defect/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "nested context changes" do
    it "refuses to silently switch tenants mid-operation" do
      Nexus::Tenancy::Context.with(organization_id: acme_id) do
        expect { Nexus::Tenancy::Context.with(organization_id: globex_id) { :never } }
          .to raise_error(Nexus::Tenancy::Context::Conflict, /nested tenant context change/)
      end
    end
  end
end
