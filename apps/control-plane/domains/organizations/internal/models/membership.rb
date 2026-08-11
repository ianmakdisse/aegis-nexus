# frozen_string_literal: true

module Nexus
  module Organizations
    module Internal
      module Models
        # The user <-> tenant link. Roles are held THROUGH a membership, never
        # globally on a user (see docs/01-product/domain-glossary.md).
        class Membership < TenantScopedRecord
          self.table_name = "memberships"

          belongs_to :organization, class_name: "Nexus::Organizations::Internal::Models::Organization"

          validates :user_id, presence: true,
                              uniqueness: { scope: :organization_id }
        end
      end
    end
  end
end
