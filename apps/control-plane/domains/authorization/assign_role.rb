# frozen_string_literal: true

module Nexus
  module Authorization
    # Published contract: bind a role to a subject — a membership (human) or a
    # service identity (machine).
    #
    # THE BOOTSTRAP PROBLEM, MADE EXPLICIT
    #
    # Granting a role is itself a CRITICAL permission (`grants.create`). The
    # first grant in a tenant therefore has nobody to authorize it: the founding
    # owner cannot be made an owner by an owner. Every system solves this
    # somehow, and the failure mode is always the same — an unauthenticated code
    # path that nobody can find later.
    #
    # So the hatch is a required argument rather than an absent check:
    #
    #   AssignRole.call(role_key: "owner", membership_id: id, authorized_by: :system_bootstrap)
    #   AssignRole.call(role_key: "admin", membership_id: id, authorized_by: current_principal)
    #
    # `authorized_by:` cannot be omitted and cannot be nil. `:system_bootstrap`
    # is one grep away from a complete list of every place authority is created
    # without a human behind it, and each of those places is reviewable on that
    # basis alone.
    class AssignRole
      Error = Class.new(StandardError)
      UnknownRole = Class.new(Error)

      SYSTEM_BOOTSTRAP = :system_bootstrap

      def self.call(...) = new.call(...)

      # @param role_key [String] key of a role in the current tenant, e.g. "operator"
      # @param membership_id [String, nil] exactly one of membership_id / service_identity_id
      # @param service_identity_id [String, nil]
      # @param authorized_by [#organization_id, :system_bootstrap] who is granting
      # @param conditions [Hash] ABAC conditions the grant is contingent on
      # @param expires_at [Time, nil] nil means no expiry
      def call(role_key:, authorized_by:, membership_id: nil, service_identity_id: nil,
               conditions: {}, expires_at: nil)
        authorize!(authorized_by)

        role = Internal::Models::Role.find_by(key: role_key.to_s)
        raise UnknownRole, "no role `#{role_key}` in this tenant" if role.nil?

        grant = Internal::Models::Grant.new(
          role_id: role.id,
          membership_id: membership_id,
          service_identity_id: service_identity_id,
          conditions: conditions,
          expires_at: expires_at
        )

        raise Error, "could not assign role: #{grant.errors.full_messages.join(', ')}" unless grant.save

        grant.id
      end

      private

      def authorize!(authorized_by)
        return if authorized_by == SYSTEM_BOOTSTRAP

        raise ArgumentError, "authorized_by: is required" if authorized_by.nil?

        Authorize.call!(authorized_by, :create, :grants)
      end
    end
  end
end
