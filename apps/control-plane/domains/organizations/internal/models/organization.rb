# frozen_string_literal: true

module Nexus
  module Organizations
    module Internal
      module Models
        # The tenant root. NOT a TenantScopedRecord: an organization *is* the
        # tenant, so its RLS policy keys on `id` rather than a self-referential
        # organization_id (see db/migrate/*_enable_row_level_security.rb).
        class Organization < ApplicationRecord
          self.table_name = "organizations"

          TIERS = %w[pool dedicated].freeze

          has_many :memberships, class_name: "Nexus::Organizations::Internal::Models::Membership",
                                 foreign_key: :organization_id, inverse_of: :organization, dependent: :restrict_with_exception

          validates :name, :slug, :region_code, presence: true
          validates :slug, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }
          validates :tier, inclusion: { in: TIERS }

          # Mirrors the database CHECK constraint. Duplicated deliberately: the
          # constraint is the guarantee, the validation is the good error message.
          validate :placement_consistent

          def dedicated? = tier == "dedicated"

          private

          def placement_consistent
            if dedicated? && database_key.blank?
              errors.add(:database_key, "is required for dedicated-tier tenants (they are unroutable without it)")
            elsif !dedicated? && database_key.present?
              errors.add(:database_key, "must be null for pool-tier tenants")
            end
          end
        end
      end
    end
  end
end
