# frozen_string_literal: true

module Nexus
  module Authorization
    module Internal
      module Models
        # The global permission catalog. Platform-global by construction: a
        # permission key describes the software, not a tenant, and carries no
        # tenant data — so it inherits ApplicationRecord rather than
        # TenantScopedRecord and has no RLS policy.
        #
        # This is one of the two deliberate exceptions to INV-13 inside this
        # context (the other is `users`, in Identity). Both are recorded in the
        # RLS migration and in docs/03-domains/authorization/README.md; adding a
        # third requires an ADR.
        class Permission < ApplicationRecord
          self.table_name = "permissions"
          self.primary_key = "key"

          validates :key, :resource_type, :action, presence: true
          validates :risk_tier, inclusion: { in: Catalog::RISK_TIERS }
        end
      end
    end
  end
end
