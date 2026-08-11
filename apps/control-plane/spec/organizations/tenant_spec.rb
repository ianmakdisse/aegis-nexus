# frozen_string_literal: true

require "rails_helper"

# ADR-013 — platform processes enumerate tenants from a directory, because a
# correctly isolated system cannot list its own tenants.
RSpec.describe Nexus::Organizations::Tenant do
  describe "the problem this exists to solve" do
    # The finding that produced ADR-013. Stated as a test so that if the
    # isolation model ever changes, this fails and the ADR gets revisited
    # rather than quietly becoming wrong.
    it "confirms organizations cannot be listed with no tenant set" do
      provision_organization!(name: "A", slug: "a-#{SecureRandom.hex(4)}")

      # Clear the DATABASE session variable, which is what layer (a) reads.
      # This is the state a relay process is in: no tenant established.
      ActiveRecord::Base.connection.execute("SET LOCAL nexus.organization_id = ''")
      visible = ActiveRecord::Base.connection.select_value("SELECT count(*) FROM organizations").to_i

      expect(visible).to eq(0)
    end

    # SHARP EDGE, recorded as TD-011.
    #
    # `without_tenant_for_platform_operation` clears isolation layer (c) — the
    # application's Fiber-local context. It does NOT clear layer (a), the
    # PostgreSQL session variable, because SET LOCAL is transaction-scoped and
    # survives the release of a savepoint.
    #
    # No current caller is affected: every platform-global table
    # (`permissions`, `tenant_directory`, `event_type_registry`) has no RLS
    # policy, so the stale variable changes nothing. But a future platform
    # operation that reads an RLS-protected table from inside a tenant's
    # transaction would silently see that one tenant's rows and believe it had
    # seen all of them.
    #
    # Asserted rather than fixed: changing the semantics of a core isolation
    # primitive is not a Phase 5 change, and an undocumented sharp edge is far
    # more dangerous than a documented one.
    it "does not clear the database session variable, only the application context" do
      id = provision_organization!(name: "A", slug: "a-#{SecureRandom.hex(4)}")

      leaked = ActiveRecord::Base.transaction(requires_new: true) do
        Nexus::Tenancy::Context.with(organization_id: id) do
          Nexus::Database::RowLevelSecurity.apply!

          Nexus::Tenancy::Context.without_tenant_for_platform_operation do
            expect(Nexus::Tenancy::Context.current).to be_nil          # layer (c) cleared
            ActiveRecord::Base.connection.select_value(
              "SELECT current_setting('nexus.organization_id', true)"  # layer (a) is not
            )
          end
        end
      end

      expect(leaked).to eq(id)
    end
  end

  describe "enumeration" do
    it "lists a tenant as soon as it is provisioned" do
      id = provision_organization!(name: "A", slug: "a-#{SecureRandom.hex(4)}")

      expect(described_class.active_ids).to include(id)
    end

    it "returns an enumerator so a caller streams rather than materializing 10^5 rows" do
      expect(described_class.each_active_id).to be_a(Enumerator)
    end

    it "can be filtered by region, for a regional relay" do
      seed_region!(code: "eu-west-1")
      here = provision_organization!(name: "A", slug: "a-#{SecureRandom.hex(4)}", region_code: "sa-east-1")
      there = provision_organization!(name: "B", slug: "b-#{SecureRandom.hex(4)}", region_code: "eu-west-1")

      expect(described_class.active_ids(region_code: "sa-east-1")).to include(here)
      expect(described_class.active_ids(region_code: "sa-east-1")).not_to include(there)
    end

    it "omits a tenant that is no longer active" do
      id = provision_organization!(name: "A", slug: "a-#{SecureRandom.hex(4)}")
      described_class.update_status!(organization_id: id, status: "suspended")

      expect(described_class.active_ids).not_to include(id)
      expect(described_class.find(id).status).to eq("suspended")
    end
  end

  describe "the directory cannot drift" do
    # Written in provisioning's own transaction. If the organization row rolls
    # back, so does the directory entry — a tenant that background processes
    # work for but requests cannot reach would accumulate an invisible backlog.
    it "rolls back with the organization when provisioning fails" do
      before_count = described_class.count

      expect {
        Nexus::Organizations::ProvisionOrganization.call(
          name: "Doomed", slug: nil, region_code: "sa-east-1"
        )
      }.to raise_error(StandardError)

      expect(described_class.count).to eq(before_count)
    end

    it "records placement, so a dedicated tenant is routable" do
      id = provision_organization!(name: "A", slug: "a-#{SecureRandom.hex(4)}")

      expect(described_class.find(id).tier).to eq("pool")
      expect(described_class.find(id)).not_to be_dedicated
    end
  end

  describe "it holds identifiers, not descriptions (ADR-013)" do
    # The rule with no automated enforcement, made automated. A descriptive
    # column here turns an enumeration surface into a disclosure one.
    it "exposes no tenant-describing columns" do
      columns = Nexus::Organizations::Internal::Models::TenantDirectoryEntry.column_names

      expect(columns).to match_array(%w[organization_id status region_code tier created_at updated_at])
      expect(columns).not_to include("name", "slug", "settings", "database_key")
    end
  end

  describe "the relay uses it" do
    it "enumerates tenants with no tenant context open" do
      id = provision_organization!(name: "A", slug: "a-#{SecureRandom.hex(4)}")

      expect(Nexus::Events::Relay.each_tenant_id.to_a).to include(id)
    end

    it "still accepts an injected source, for a sharded loop" do
      expect(Nexus::Events::Relay.each_tenant_id(%w[a b])).to eq(%w[a b])
      expect(Nexus::Events::Relay.each_tenant_id(-> { %w[c] })).to eq(%w[c])
    end
  end
end
