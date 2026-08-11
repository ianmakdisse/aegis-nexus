# frozen_string_literal: true

module Nexus
  module Authorization
    # Published contract: the only place in the system that decides whether a
    # principal may do something (INV-15).
    #
    #   Authorize.call!(principal, :trigger, :workflows)
    #   Authorize.call(principal, :call, :integrations, attributes: { "environment" => "production" })
    #   Authorize.permitted?(principal, :read, :billing)
    #
    # The permission key is `"#{resource_type}.#{action}"`, and it must exist in
    # the catalog — see Internal::Evaluator for why that check comes first.
    #
    # WHY THERE IS NO CACHE HERE
    #
    # Not an oversight, and not a TODO. ADR-010 Rule 1: anything that can *deny*
    # an action reads strongly consistent state. A permission revoked a moment ago
    # is revoked; honoring it for another 200 ms is not a latency optimization,
    # it is the window an attacker is removed in. Callers may hold a PermissionSet
    # for the duration of one request — that is the whole permitted lifetime.
    #
    # WHY EVERY ERROR IS A DENIAL
    #
    # A missing tenant context, an unreadable policy, a principal from the wrong
    # tenant, a database error mid-evaluation: all of these return `denied`, none
    # of them propagate. An authorization check that raises invites a caller to
    # rescue it and continue, and "the check errored so we proceeded" is how
    # fail-open gets built one rescue at a time. `call!` raises Denied — a
    # decision — rather than the underlying fault.
    #
    # The fault itself is logged at error level, because a denial caused by a
    # broken evaluator is an incident even though it is a safe outcome.
    class Authorize
      Denied = Class.new(StandardError)

      Decision = Struct.new(:allowed, :permission, :reason, :message, :policy_id, keyword_init: true) do
        def allowed? = allowed
        def denied? = !allowed
        def to_s = "#{allowed? ? 'ALLOW' : 'DENY'} #{permission} (#{reason})"
      end

      class << self
        def call(...) = new.call(...)
        def call!(...) = new.call!(...)
        def permitted?(...) = new.call(...).allowed?
      end

      # @param principal [#organization_id, #membership_id | #service_identity_id]
      # @param action [Symbol, String] e.g. :trigger
      # @param resource_type [Symbol, String] e.g. :workflows
      # @param attributes [Hash] request attributes for grant conditions and policies
      # @return [Decision]
      def call(principal, action, resource_type, attributes: {})
        Internal::Evaluator.new.call(principal, action, resource_type, attributes: attributes)
      rescue StandardError => e
        fail_closed("#{resource_type}.#{action}", e)
      end

      def call!(principal, action, resource_type, attributes: {})
        decision = call(principal, action, resource_type, attributes: attributes)
        raise Denied, decision.message if decision.denied?

        decision
      end

      private

      def fail_closed(permission_key, error)
        Rails.logger.error(
          "[authorization] evaluator failed closed for #{permission_key}: " \
          "#{error.class}: #{error.message}"
        )

        Decision.new(
          allowed: false, permission: permission_key, reason: :evaluator_error,
          message: "authorization could not be evaluated and therefore denied (#{error.class})"
        )
      end
    end
  end
end
