# frozen_string_literal: true

module Nexus
  module Authorization
    # Published contract: the platform's permission vocabulary.
    #
    # Installed once per database, not once per tenant — the rows describe the
    # software. `install!` is idempotent (INV-05 applies to operations, not only
    # to message handlers) so it can run on every boot, every deploy, and in
    # every test without a guard around it.
    #
    # WHY THIS IS PUBLIC
    #
    # Two callers outside this context need it and neither should reach into
    # `internal/`: deployment (db/seeds.rb, and later a release task) installs
    # it, and an administrative surface needs to render "here is every permission
    # that exists, and how risky each one is" without inventing its own list.
    module PermissionCatalog
      module_function

      # Idempotently reconcile the catalog table with Internal::Catalog.
      #
      # Runs with no tenant context by design: `permissions` is platform-global,
      # and pretending otherwise would mean provisioning could not install it.
      #
      # NOTE ON REMOVAL: rows no longer in the catalog are left in place rather
      # than deleted. `role_permissions.permission_key` references this table, so
      # a delete would either fail on the constraint or silently strip authority
      # from a tenant's roles. Retiring a permission is an expand/contract
      # migration (INV-11), not a side effect of editing a Ruby constant.
      def install!
        Tenancy::Context.without_tenant_for_platform_operation do
          now = Time.current

          Internal::Catalog.rows.each do |key, resource_type, action, risk_tier, description|
            record = Internal::Models::Permission.find_or_initialize_by(key: key)
            record.assign_attributes(
              resource_type: resource_type, action: action,
              risk_tier: risk_tier, description: description, updated_at: now
            )
            record.created_at ||= now
            record.save!
          end
        end

        Internal::Catalog.keys.size
      end

      # Whether the catalog has been installed. Callers that depend on it fail
      # loudly rather than producing a principal with no permissions, which would
      # otherwise present as "authorization is broken" long after the real cause.
      def installed?
        Tenancy::Context.without_tenant_for_platform_operation do
          Internal::Models::Permission.count >= Internal::Catalog.keys.size
        end
      end

      def keys = Internal::Catalog.keys

      def risk_tier(permission_key)
        Tenancy::Context.without_tenant_for_platform_operation do
          Internal::Models::Permission.where(key: permission_key).pick(:risk_tier)
        end
      end

      # [{key:, resource_type:, action:, risk_tier:, description:}, ...]
      def to_a
        Internal::Catalog.rows.map do |key, resource_type, action, risk_tier, description|
          { key: key, resource_type: resource_type, action: action,
            risk_tier: risk_tier, description: description }
        end
      end
    end
  end
end
