# frozen_string_literal: true

module Nexus
  module Organizations
    # Published contract: which tenants exist (ADR-013).
    #
    # This is the ONLY supported way for a platform process to enumerate
    # tenants. `organizations` cannot answer it — the table is RLS-protected and
    # no application role bypasses policy (INV-14) — so the answer comes from
    # `tenant_directory`, which holds identifiers and no tenant data.
    #
    # Everything a caller does *with* an id goes through the ordinary isolation
    # path: open that tenant's context, do the work, close it. Enumeration is not
    # an exemption from tenancy; it is how a process finds which tenancy to enter.
    class Tenant
      Record = Struct.new(:organization_id, :status, :region_code, :tier, keyword_init: true) do
        def active? = status == "active"
        def dedicated? = tier == "dedicated"
      end

      ACTIVE = "active"

      class << self
        # Ids of tenants a background process should be working for.
        #
        # Returns an Enumerator rather than an Array so a caller streams rather
        # than materializing every tenant — at 10⁵ tenants the difference between
        # those two is the difference between a loop and an outage.
        def each_active_id(region_code: nil, &block)
          return enum_for(:each_active_id, region_code: region_code) if block.nil?

          scope = directory.where(status: ACTIVE)
          scope = scope.where(region_code: region_code) if region_code
          scope.order(:organization_id).pluck(:organization_id).each(&block)
        end

        def active_ids(region_code: nil) = each_active_id(region_code: region_code).to_a

        def find(organization_id)
          row = directory.find_by(organization_id: organization_id)
          row && to_record(row)
        end

        def exists?(organization_id) = directory.exists?(organization_id: organization_id)

        def count(status: ACTIVE) = directory.where(status: status).count

        # Called by ProvisionOrganization inside its transaction. Not public
        # beyond this context's contract: a directory entry without an
        # organization row would be a tenant that background processes work for
        # and requests cannot reach.
        def register!(organization_id:, region_code:, tier: "pool", status: ACTIVE)
          Internal::Models::TenantDirectoryEntry.create!(
            organization_id: organization_id, region_code: region_code,
            tier: tier, status: status
          )
        end

        def update_status!(organization_id:, status:)
          directory.where(organization_id: organization_id).update_all(status: status, updated_at: Time.current)
        end

        private

        # The directory is platform-global, so it is read with no tenant context.
        # Stated explicitly rather than relied upon: every other query in this
        # context is tenant-scoped, and a reader should not have to infer which.
        def directory
          Tenancy::Context.without_tenant_for_platform_operation do
            Internal::Models::TenantDirectoryEntry.all
          end
        end

        def to_record(row)
          Record.new(organization_id: row.organization_id, status: row.status,
                     region_code: row.region_code, tier: row.tier)
        end
      end
    end
  end
end
