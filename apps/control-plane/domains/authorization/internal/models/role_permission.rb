# frozen_string_literal: true

module Nexus
  module Authorization
    module Internal
      module Models
        # Attaches a catalog permission to a tenant's role.
        #
        # Tenant-scoped even though the permission key it points at is global:
        # the *attachment* is the tenant's decision, and it is the attachment an
        # attacker would want to add.
        class RolePermission < TenantScopedRecord
          self.table_name = "role_permissions"

          belongs_to :role, class_name: "Nexus::Authorization::Internal::Models::Role"

          validates :permission_key, presence: true
          validates :permission_key, uniqueness: { scope: :role_id }
        end
      end
    end
  end
end
