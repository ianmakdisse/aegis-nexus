# frozen_string_literal: true

module Nexus
  module Organizations
    module Internal
      module Models
        # The platform tenant directory (ADR-013).
        #
        # ApplicationRecord, not TenantScopedRecord: this table locates tenants
        # and therefore cannot itself be tenant-scoped. It is the one place in
        # this context where that is true, which is why it says so here.
        #
        # It holds identifiers, never descriptions. Adding a name, slug, or
        # setting would turn enumeration into disclosure and requires a new ADR.
        class TenantDirectoryEntry < ApplicationRecord
          self.table_name = "tenant_directory"
          self.primary_key = "organization_id"

          STATUSES = %w[active suspended closed].freeze

          validates :organization_id, :region_code, presence: true
          validates :status, inclusion: { in: STATUSES }
        end
      end
    end
  end
end
