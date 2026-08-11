# frozen_string_literal: true

module Nexus
  module Authorization
    # Published contract: the set of permission keys a principal actually holds.
    #
    # WHAT A PRINCIPAL IS HERE
    #
    # Anything that responds to `organization_id` and to one of `membership_id`
    # (a human in this tenant) or `service_identity_id` (a machine). Identity
    # publishes `Identity::Principal`, but this context never names that
    # constant: authorization is not allowed to call Identity synchronously, and
    # it does not need to. It needs an opaque subject identifier and a tenant,
    # both of which the caller already has.
    #
    # A principal MAY also respond to `acting_for`, returning the principal it is
    # acting on behalf of. That is the delegation chain, and it is the reason
    # this class exists as a first-class thing rather than as a query inside the
    # evaluator.
    #
    # INV-16 — DELEGATED AUTHORITY ONLY NARROWS
    #
    # `effective_for` walks the chain and intersects. There is deliberately no
    # union anywhere in this file, and no code path that adds a key to a set
    # after construction. An agent invoked by a viewer has a viewer's authority
    # even if the agent's own service identity is an owner — otherwise anyone who
    # can influence an agent's input inherits the agent's rights, and the agent
    # runtime becomes a privilege-escalation device with an audit trail.
    class PermissionSet
      # Depth is bounded because a delegation cycle would otherwise be an
      # infinite loop inside an authorization check — a denial-of-service in the
      # one component that everything else waits on.
      MAX_DELEGATION_DEPTH = 4

      TenantMismatch = Class.new(StandardError)
      DelegationTooDeep = Class.new(StandardError)

      attr_reader :keys

      def initialize(keys)
        @keys = Set.new(Array(keys).map(&:to_s)).freeze
        freeze
      end

      def self.empty = new([])

      # Permissions from the principal's OWN grants, ignoring delegation.
      # Grants whose conditions are not satisfied by `attributes` contribute
      # nothing — a conditional grant is not a grant until its condition holds.
      def self.for(principal, attributes: {})
        assert_same_tenant!(principal)

        grants = subject_grants(principal)
        return empty if grants.nil?

        applicable = grants.select { |g| Internal::AttributeMatch.satisfied?(g.conditions, attributes) }
        return empty if applicable.empty?

        new(
          Internal::Models::RolePermission
            .where(role_id: applicable.map(&:role_id).uniq)
            .pluck(:permission_key)
        )
      end

      # Permissions after the delegation chain is applied: the intersection of
      # this principal's set with every principal it acts for.
      def self.effective_for(principal, attributes: {}, depth: 0)
        raise DelegationTooDeep, "delegation chain deeper than #{MAX_DELEGATION_DEPTH}" if depth > MAX_DELEGATION_DEPTH

        own = self.for(principal, attributes: attributes)
        invoker = principal.respond_to?(:acting_for) ? principal.acting_for : nil
        return own if invoker.nil?

        own.intersect(effective_for(invoker, attributes: attributes, depth: depth + 1))
      end

      def include?(key) = keys.include?(key.to_s)
      def intersect(other) = self.class.new(keys & other.keys)
      def empty? = keys.empty?
      def size = keys.size
      def to_a = keys.to_a.sort

      class << self
        private

        # The principal must belong to the tenant whose context is open. A
        # mismatch is not a denial to be logged and moved past — it means a
        # principal from one tenant is being evaluated against another tenant's
        # grants, which is either a routing bug or an attack.
        def assert_same_tenant!(principal)
          current = Tenancy::Context.organization_id
          return if principal.organization_id.to_s == current.to_s

          raise TenantMismatch,
                "principal belongs to #{principal.organization_id} but the open tenant context is #{current}"
        end

        # Exactly one subject kind, mirroring the CHECK constraint on `grants`.
        # A principal that is neither, or both, resolves to no grants at all.
        def subject_grants(principal)
          membership = principal.respond_to?(:membership_id) ? principal.membership_id : nil
          service = principal.respond_to?(:service_identity_id) ? principal.service_identity_id : nil

          return nil unless [membership, service].compact.size == 1

          if membership
            Internal::Models::Grant.active.for_membership(membership).to_a
          else
            Internal::Models::Grant.active.for_service_identity(service).to_a
          end
        end
      end
    end
  end
end
