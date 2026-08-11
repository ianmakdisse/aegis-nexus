# frozen_string_literal: true

module Nexus
  module Authorization
    # Published contract: an ABAC policy, as an immutable value.
    #
    # WHAT A POLICY CAN AND CANNOT DO
    #
    # A policy **refines** a decision; it never widens one. If the principal's
    # roles do not carry the permission, no `allow` policy can conjure it. This
    # is the same shape as INV-16 (delegation only narrows), applied to
    # attributes instead of principals, and it means a mistake in a policy can
    # cost availability but never authority.
    #
    # An `allow` policy therefore has exactly one job: carve an exception out of
    # a broader `deny`. "Deny production integration calls, except from the
    # release service identity" is two policies, and the exception is the one
    # with the lower priority number.
    #
    # PRECEDENCE
    #
    #   1. Policies are considered in ascending `priority` (lower wins).
    #   2. The first policy that matches decides.
    #   3. A tie, an unreadable matcher, or an evaluation error resolves to deny.
    #
    # Rule 3 is why an unknown clause in a matcher makes a `deny` policy match
    # and an `allow` policy not match: both directions fail closed, so a policy
    # written against a future version of this evaluator degrades to "more
    # restrictive", never to "unenforced".
    class Policy
      # Everything the matcher may test. Adding a clause here is a change to the
      # policy language and needs the docs to move with it (INV-26).
      CLAUSES = %w[permissions resource_types actions risk_tiers attributes].freeze

      # The decision being evaluated, in the terms a policy can match on.
      Request = Struct.new(:permission_key, :resource_type, :action, :risk_tier, :attributes,
                           keyword_init: true) do
        def attributes = self[:attributes] || {}
      end

      attr_reader :id, :name, :effect, :matcher, :priority

      def initialize(id:, name:, effect:, matcher:, priority:)
        @id = id
        @name = name
        @effect = effect.to_s
        @matcher = matcher.is_a?(Hash) ? matcher : nil
        @priority = priority
        freeze
      end

      def self.from_record(record)
        new(id: record.id, name: record.name, effect: record.effect,
            matcher: record.matcher, priority: record.priority)
      end

      # All policies for the tenant in the current context, in precedence order.
      # Read fresh on every call: authorization never serves a cached decision
      # (ADR-010 Rule 1), and a policy revoked 200 ms ago is revoked.
      def self.for_current_tenant
        Internal::Models::PolicyRecord.in_precedence_order.map { |r| from_record(r) }
      end

      def deny? = effect == "deny"
      def allow? = effect == "allow"

      def matches?(request)
        return deny? if matcher.nil?           # unreadable matcher — fail closed
        return deny? if unknown_clauses.any?   # future syntax — fail closed

        CLAUSES.all? { |clause| clause_matches?(clause, request) }
      end

      private

      def unknown_clauses = matcher.keys.map(&:to_s) - CLAUSES

      # An absent clause is "any" — a matcher that names nothing matches
      # everything, which is why an empty deny policy is a tenant-wide lockout
      # and is exactly as dangerous as it sounds.
      def clause_matches?(clause, request)
        expected = matcher[clause] || matcher[clause.to_sym]
        return true if expected.nil?

        case clause
        when "permissions"    then Array(expected).include?(request.permission_key)
        when "resource_types" then Array(expected).include?(request.resource_type)
        when "actions"        then Array(expected).include?(request.action)
        when "risk_tiers"     then Array(expected).include?(request.risk_tier)
        when "attributes"     then Internal::AttributeMatch.satisfied?(expected, request.attributes)
        end
      end
    end
  end
end
