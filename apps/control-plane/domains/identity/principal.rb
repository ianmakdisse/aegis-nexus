# frozen_string_literal: true

module Nexus
  module Identity
    # Published contract: who is making a request.
    #
    # This is the value object every other context receives, and it is
    # deliberately anaemic. It carries **identifiers only** — no password digest,
    # no token, no MFA secret, no email. Credential material never leaves this
    # context, so no other context can leak what it was never given (INV-18).
    #
    # It also carries no permissions. A principal is an answer to "who", and
    # `Authorization::Authorize` answers "may they" from live state on every
    # request (ADR-011, ADR-010 Rule 1).
    #
    # THE SHAPE AUTHORIZATION EXPECTS
    #
    # Authorization accepts anything responding to `organization_id` plus exactly
    # one of `membership_id` / `service_identity_id`, and optionally `acting_for`.
    # It never names this class — it is not permitted to call Identity
    # synchronously and does not need to. This object satisfies that structure,
    # which is why `Authorize.call!(principal, ...)` works without either context
    # depending on the other's types.
    class Principal
      KINDS = %w[user service agent].freeze

      attr_reader :kind, :user_id, :organization_id, :membership_id,
                  :service_identity_id, :scopes, :token_id, :acting_for

      def initialize(kind:, organization_id:, user_id: nil, membership_id: nil,
                     service_identity_id: nil, scopes: [], token_id: nil, acting_for: nil)
        raise ArgumentError, "unknown principal kind #{kind.inspect}" unless KINDS.include?(kind.to_s)
        raise ArgumentError, "a principal always has a tenant" if organization_id.blank?

        @kind = kind.to_s
        @organization_id = organization_id
        @user_id = user_id
        @membership_id = membership_id
        @service_identity_id = service_identity_id
        @scopes = Array(scopes).map(&:to_s).freeze
        @token_id = token_id
        @acting_for = acting_for
        validate_subject!
        freeze
      end

      def self.human(organization_id:, user_id:, membership_id:, **rest)
        new(kind: "user", organization_id: organization_id, user_id: user_id,
            membership_id: membership_id, **rest)
      end

      def self.machine(organization_id:, service_identity_id:, kind: "service", **rest)
        new(kind: kind, organization_id: organization_id,
            service_identity_id: service_identity_id, **rest)
      end

      # The identifier this principal is known by in its own credential store.
      # Not a globally unique key across kinds — that is the point of `kind`.
      def subject_id = human? ? user_id : service_identity_id

      def human? = kind == "user"
      def machine? = !human?

      # Delegation (INV-16). Returns a NEW principal — the receiver is frozen, so
      # there is no path by which an agent's authority is widened in place after
      # it has been constructed and checked.
      def acting_on_behalf_of(other)
        self.class.new(
          kind: kind, organization_id: organization_id, user_id: user_id,
          membership_id: membership_id, service_identity_id: service_identity_id,
          scopes: scopes, token_id: token_id, acting_for: other
        )
      end

      # Safe for logs, traces, and audit records: identifiers only, by
      # construction, because that is all this object holds.
      def to_log
        {
          kind: kind, organization_id: organization_id, user_id: user_id,
          membership_id: membership_id, service_identity_id: service_identity_id,
          token_id: token_id, acting_for: acting_for&.to_log
        }.compact
      end

      def ==(other)
        other.is_a?(Principal) && other.to_log == to_log && other.scopes == scopes
      end

      private

      # Exactly one subject, mirroring the CHECK constraint on `grants`. A
      # principal that is both, or neither, would resolve to an ambiguous grant
      # lookup — so it cannot be constructed at all.
      def validate_subject!
        subjects = [membership_id, service_identity_id].compact
        return if subjects.size == 1

        raise ArgumentError,
              "a principal is exactly one subject: a membership or a service identity, " \
              "never both and never neither"
      end
    end
  end
end
