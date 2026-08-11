# frozen_string_literal: true

module Nexus
  module Identity
    module Internal
      module Models
        # A non-human principal (FR-106). `kind` distinguishes a service (a
        # deployed component acting for itself) from an agent (an AI actor whose
        # authority is always narrowed by whoever invoked it — INV-16).
        #
        # Tenant-scoped: unlike users, a machine identity belongs to exactly one
        # organization. There is no such thing as a service identity shared
        # across tenants, and the RLS policy on this table is what stops one
        # from being created by accident.
        class ServiceIdentity < TenantScopedRecord
          self.table_name = "service_identities"

          KINDS = %w[service agent].freeze

          validates :name, presence: true, uniqueness: { scope: :organization_id }
          validates :kind, inclusion: { in: KINDS }
          validates :token_digest, presence: true

          scope :live, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > now()") }

          def revoked? = revoked_at.present?
        end
      end
    end
  end
end
