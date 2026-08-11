# frozen_string_literal: true

module Nexus
  module Identity
    # Published contract: turn a verified identity into usable credentials, and
    # rotate them (FR-109, ADR-011).
    #
    #   IssueToken.for_user(user_id:, organization_id:)      → Result   (login)
    #   IssueToken.refresh(refresh_token:, organization_id:) → Result   (rotation)
    #
    # `organization_id` is required on both. A refresh token is opaque and
    # carries no tenant, and `sessions` is RLS-protected, so the tenant has to
    # come from the request — which the client always knows, because the access
    # token it just held said so. Requiring it here is what keeps session lookups
    # inside RLS instead of reaching around it.
    #
    # This is also where membership is verified. Authenticating proves a person
    # exists; it says nothing about whether they belong to the organization they
    # are asking for. A verified human with no active membership gets no
    # credentials — which is the whole reason authentication returns a
    # `VerifiedUser` and not a `Principal`.
    class IssueToken
      Failed = Class.new(StandardError)

      # Not a subclass of Failed by accident of hierarchy — a reuse detection is
      # a security event, not a bad request. It should page, not increment a 401
      # counter.
      ReuseDetected = Class.new(StandardError)

      REFRESH_LIFETIME = 30.days

      Result = Struct.new(:principal, :access_token, :refresh_token,
                          :access_expires_at, :refresh_expires_at, :session_id,
                          keyword_init: true)

      class << self
        def for_user(...) = new.for_user(...)
        def refresh(...) = new.refresh(...)
      end

      def for_user(user_id:, organization_id:, scopes: [], user_agent: nil, ip_address: nil)
        within_tenant(organization_id) do
          membership = require_membership!(user_id, organization_id)

          session = create_session!(
            user_id: user_id, family_id: SecureRandom.uuid,
            user_agent: user_agent, ip_address: ip_address
          )

          build_result(session, membership, scopes)
        end
      end

      # Rotation. Every refresh invalidates the token that was presented and
      # issues a new one in the same family, so a token is usable exactly once.
      def refresh(refresh_token:, organization_id:, scopes: [], user_agent: nil, ip_address: nil)
        outcome = within_tenant(organization_id) do
          session = Internal::Models::Session.find_by(
            refresh_token_digest: Internal::TokenDigest.digest(refresh_token)
          )

          raise Failed, "unknown refresh token" if session.nil?

          # A rotated token presented a second time means two parties hold it, and
          # we cannot tell which one is the thief. So the whole family dies: the
          # legitimate user is logged out too, which is the correct bias when the
          # alternative is leaving an attacker with a live session.
          #
          # The detection RETURNS rather than raises, and the error is raised
          # after the transaction commits. Raising here would roll back the very
          # revocations that are the response to the theft — the system would
          # detect the replay, report it, and leave the attacker's session live.
          # That bug existed until the test asserted the victim's token was dead
          # too.
          next reuse_outcome(session) if session.revoked?

          raise Failed, "refresh token expired" if session.expires_at <= Time.current

          membership = require_membership!(session.user_id, organization_id)

          session.revoke!
          rotated = create_session!(
            user_id: session.user_id, family_id: session.family_id,
            user_agent: user_agent, ip_address: ip_address
          )

          build_result(rotated, membership, scopes)
        end

        raise ReuseDetected, "refresh token replayed — session family revoked" if outcome == REUSE

        outcome
      end

      private

      REUSE = :reuse_detected
      private_constant :REUSE

      # SET LOCAL is transaction-scoped, so the RLS session variable and the work
      # it governs have to share one transaction — the same shape provisioning
      # uses. Nesting with the same tenant is allowed; a *different* tenant
      # raises, which is what catches a routing bug before it becomes a
      # cross-tenant write.
      def within_tenant(organization_id, &block)
        ActiveRecord::Base.transaction(requires_new: true) do
          Tenancy::Context.with(organization_id: organization_id) do
            Database::RowLevelSecurity.apply!
            block.call
          end
        end
      end

      def require_membership!(user_id, organization_id)
        membership = Nexus::Organizations::Membership.active_for_user(user_id: user_id)
        raise Failed, "no active membership in #{organization_id}" if membership.nil?

        membership
      end

      def create_session!(user_id:, family_id:, user_agent:, ip_address:)
        raw = Internal::TokenDigest.generate

        session = Internal::Models::Session.create!(
          user_id: user_id,
          refresh_token_digest: Internal::TokenDigest.digest(raw),
          family_id: family_id,
          user_agent: user_agent,
          ip_address: ip_address,
          expires_at: REFRESH_LIFETIME.from_now
        )

        # The plaintext exists only here and in the Result. It is never stored,
        # and it is never reachable from the session row again.
        session.define_singleton_method(:plaintext) { raw }
        session
      end

      # Revokes every live session in the family and reports what happened to the
      # caller, which raises once the revocations are durable.
      def reuse_outcome(session)
        Internal::Models::Session.in_family(session.family_id)
                                 .where(revoked_at: nil)
                                 .find_each { |s| s.revoke! }

        Rails.logger.error(
          "[identity] refresh token reuse detected; revoked session family " \
          "#{session.family_id} for user #{session.user_id}"
        )

        REUSE
      end

      def build_result(session, membership, scopes)
        principal = Principal.human(
          organization_id: session.organization_id,
          user_id: session.user_id,
          membership_id: membership.id,
          scopes: scopes,
          token_id: SecureRandom.uuid
        )

        Result.new(
          principal: principal,
          access_token: Internal::AccessToken.issue(principal: principal, scopes: scopes),
          refresh_token: session.plaintext,
          access_expires_at: Internal::AccessToken::LIFETIME.from_now,
          refresh_expires_at: session.expires_at,
          session_id: session.id
        )
      end
    end
  end
end
