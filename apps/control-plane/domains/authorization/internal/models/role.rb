# frozen_string_literal: true

module Nexus
  module Authorization
    module Internal
      module Models
        # Roles are tenant-scoped so a tenant may define its own. System roles
        # are seeded per tenant rather than shared globally, which keeps every
        # authorization query inside one tenant's rows — and therefore inside RLS.
        class Role < TenantScopedRecord
          self.table_name = "roles"

          has_many :role_permissions,
                   class_name: "Nexus::Authorization::Internal::Models::RolePermission",
                   dependent: :destroy

          validates :key, :name, presence: true
          validates :key, uniqueness: { scope: :organization_id }

          def permission_keys = role_permissions.pluck(:permission_key)
        end
      end
    end
  end
end
