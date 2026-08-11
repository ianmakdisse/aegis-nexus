# frozen_string_literal: true

module Nexus
  module Authorization
    # Public contract: create a new tenant's built-in roles.
    #
    # This exists because `boundary-check` caught the alternative. Tenant
    # provisioning lives in the Organizations context and originally inserted
    # into `roles` directly — a table Authorization owns. That is exactly the
    # cross-context table access INV-01 forbids, and the build failed on it.
    #
    # The fix is not to widen the rule but to publish the capability: Authorization
    # owns what a role is and what the system roles are, so it exposes an
    # operation for creating them and Organizations calls it. Organizations still
    # cannot see the table, and Authorization stays free to change its schema.
    #
    # `organizations -> authorization` is already a declared synchronous edge in
    # config/ownership.yml (provisioning cannot complete without the roles, and
    # a half-provisioned tenant is unreachable).
    class SeedSystemRoles
      # The built-in roles every tenant gets, and what each one may do, are
      # defined by Internal::Catalog::ROLE_TEMPLATES. Permission attachments are
      # written as explicit rows rather than resolved at request time — see the
      # Catalog comment for why "what can an admin do?" must be a query.
      CatalogNotInstalled = Class.new(StandardError)

      def self.call(...) = new.call(...)

      # Must be called inside the target tenant's context: the rows it writes are
      # tenant-scoped and RLS will reject them otherwise. Failing loudly here is
      # better than failing obscurely at the INSERT.
      #
      # Idempotent, so re-running it after a catalog change reconciles a tenant's
      # system roles to the current templates. It only ever adds attachments to
      # roles flagged `system`: a tenant that has edited a built-in role, or
      # created its own, is not silently overwritten.
      def call
        organization_id = Tenancy::Context.organization_id
        assert_catalog_installed!

        Internal::Catalog::ROLE_TEMPLATES.map do |key, template|
          role = upsert_role(organization_id, key, template)
          attach_permissions(role, Internal::Catalog.permissions_for(key)) if role.system?
          role
        end
      end

      private

      # NOT `create_or_find_by!`, which was the original implementation and was
      # not idempotent at all. That method builds the record, saves it, and
      # rescues ActiveRecord::RecordNotUnique from the database's unique index —
      # but `Role` validates key uniqueness in Ruby, so the second run fails
      # validation and raises RecordInvalid before any INSERT is attempted. The
      # rescue never fires and the "idempotent" seed blows up.
      #
      # `find_or_create_by!` checks first, which is the behavior wanted here. It
      # is not race-free on its own, so the concurrent case is rescued explicitly
      # rather than left to look like it cannot happen.
      def upsert_role(organization_id, key, template)
        Internal::Models::Role.find_or_create_by!(organization_id: organization_id, key: key) do |r|
          r.name = template[:name]
          r.system = true
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        Internal::Models::Role.find_by!(key: key)
      end

      # Bulk insert: a tenant's four system roles carry ~110 attachments between
      # them, and provisioning is a synchronous request. One statement per role
      # instead of one per permission is the difference between a fast tenant
      # creation and a slow one.
      #
      # `insert_all!` skips validations and callbacks, so organization_id and the
      # timestamps are set explicitly here — TenantScopedRecord's stamping
      # callback does not run. RLS still applies: the database rejects the batch
      # if the session's tenant disagrees, which is precisely why layer (a) is
      # not implemented in Ruby.
      def attach_permissions(role, permission_keys)
        missing = permission_keys - role.permission_keys
        return if missing.empty?

        now = Time.current
        Internal::Models::RolePermission.insert_all!(
          missing.map do |permission_key|
            { organization_id: role.organization_id, role_id: role.id,
              permission_key: permission_key, created_at: now, updated_at: now }
          end
        )
      end

      # A tenant provisioned against an empty catalog gets four roles that grant
      # nothing — including an owner who cannot administer their own
      # organization. That failure surfaces days later as "permissions are
      # broken", so it is caught here, at the only moment where the cause is
      # still obvious.
      def assert_catalog_installed!
        return if PermissionCatalog.installed?

        raise CatalogNotInstalled,
              "the permission catalog is not installed in this database. " \
              "Run Nexus::Authorization::PermissionCatalog.install! (db/seeds.rb does this) " \
              "before provisioning tenants."
      end
    end
  end
end
