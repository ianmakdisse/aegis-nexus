# frozen_string_literal: true

require "bcrypt"

module Nexus
  module Identity
    # Published contract: prove who is calling.
    #
    # Two entry points, because there are two genuinely different questions:
    #
    #   Authenticate.password(email:, password:, mfa_code:)  → VerifiedUser
    #   Authenticate.bearer(token)                           → Principal
    #
    # `password` identifies a **human, globally** — it runs outside any tenant
    # context, because `users` is a platform-global table and a person may belong
    # to several organizations. It deliberately does NOT return a principal: a
    # principal is authority inside one tenant, and which tenant has not been
    # decided at this point. `IssueToken.for_user` is the step that binds the
    # verified human to an organization, and it fails if there is no membership.
    #
    # Splitting it this way is what keeps a credential check from ever running
    # inside the wrong tenant's context, or worse, inside none at all while
    # touching tenant-scoped rows.
    #
    # UNIFORM FAILURE
    #
    # Every failure raises `Failed` with the same message. Not "no such user",
    # not "wrong password", not "MFA required" — those are an account enumeration
    # oracle, and the "helpful" version is how an attacker turns a leaked email
    # list into a target list. The specific reason is attached for the audit log
    # and is never rendered to the caller.
    class Authenticate
      Failed = Class.new(StandardError) do
        def initialize(reason = :invalid_credentials)
          @reason = reason
          super("authentication failed")
        end

        attr_reader :reason
      end

      VerifiedUser = Struct.new(:user_id, :email, :mfa_used, keyword_init: true)

      class << self
        def password(...) = new.password(...)
        def bearer(...) = new.bearer(...)
      end

      def password(email:, password:, mfa_code: nil)
        user = find_user(email)

        # Always run bcrypt, even with no user, against a fixed dummy digest.
        # Returning early on "no such user" makes the response measurably faster
        # for unknown addresses, which is the same enumeration oracle as a
        # distinct error message — just delivered by a stopwatch.
        verified = verify_password(user, password)

        raise Failed, :invalid_credentials unless verified
        raise Failed, :inactive_user unless user.active?

        mfa_used = check_second_factor!(user, mfa_code)

        # Advances the TOTP replay floor as well as recording the login: a code
        # from an interval at or before this instant will not be accepted again.
        user.update!(last_authenticated_at: Time.current)

        VerifiedUser.new(user_id: user.id, email: user.email, mfa_used: mfa_used)
      end

      # Resolve a bearer credential to a principal. Accepts both machine tokens
      # (`nxs_…`) and access tokens (JWT); the format is self-describing, so
      # callers do not have to know which kind they were handed.
      def bearer(raw_token)
        raise Failed, :missing_token if raw_token.blank?

        if Internal::ServiceToken.looks_like?(raw_token)
          authenticate_service(raw_token)
        else
          authenticate_access_token(raw_token)
        end
      end

      private

      # `users` is platform-global. Reading it outside a tenant context is
      # correct here and is stated explicitly rather than relied upon.
      def find_user(email)
        return nil if email.blank?

        Tenancy::Context.without_tenant_for_platform_operation do
          Internal::Models::User.with_email(email).first
        end
      end

      def verify_password(user, password)
        digest = user&.password_digest.presence || dummy_digest
        matched = BCrypt::Password.new(digest).is_password?(password.to_s)

        matched && !user.nil? && user.password_set?
      rescue BCrypt::Errors::InvalidHash
        false
      end

      # A real bcrypt digest of a value nothing can present, memoized so the cost
      # is paid once per process rather than once per failed login.
      def dummy_digest
        self.class.instance_variable_get(:@dummy_digest) ||
          self.class.instance_variable_set(:@dummy_digest, BCrypt::Password.create(SecureRandom.hex(32)))
      end

      # @return [Boolean] whether a second factor was actually used
      def check_second_factor!(user, mfa_code)
        return false unless Internal::Mfa.enabled?(user)

        unless Internal::Mfa.verify(user, mfa_code, after: user.last_authenticated_at)
          raise Failed, :invalid_mfa_code
        end

        true
      end

      # Stateless by design (ADR-011): a valid signature is proof of identity for
      # up to 15 minutes and there is no session lookup here. Authority is still
      # evaluated per request against live state, so a revoked *permission* stops
      # this principal immediately even while the token remains valid.
      def authenticate_access_token(raw_token)
        claims = Internal::AccessToken.verify(raw_token)

        Principal.new(
          kind: claims["knd"],
          organization_id: claims["org"],
          user_id: claims["knd"] == "user" ? claims["sub"] : nil,
          membership_id: claims["mbr"],
          service_identity_id: claims["knd"] == "user" ? nil : claims["sub"],
          scopes: claims["scp"],
          token_id: claims["jti"]
        )
      rescue Internal::AccessToken::Invalid
        raise Failed, :invalid_access_token
      rescue ArgumentError
        # A structurally impossible principal — e.g. a token claiming to be a
        # human with no membership. Malformed authority is denied authority.
        raise Failed, :malformed_token_subject
      end

      def authenticate_service(raw_token)
        parsed = Internal::ServiceToken.parse(raw_token)
        raise Failed, :malformed_service_token if parsed.nil?

        identity = find_service_identity(parsed)
        raise Failed, :unknown_service_token if identity.nil?

        unless Internal::TokenDigest.matches?(parsed.secret, identity.token_digest)
          raise Failed, :invalid_service_token
        end

        Principal.machine(
          organization_id: identity.organization_id,
          service_identity_id: identity.id,
          kind: identity.kind,
          scopes: identity.scopes
        )
      end

      # The lookup runs inside the tenant the credential names, so RLS is active
      # throughout — authentication never runs with isolation switched off. A
      # forged tenant segment simply opens a context where nothing matches.
      def find_service_identity(parsed)
        ActiveRecord::Base.transaction(requires_new: true) do
          Tenancy::Context.with(organization_id: parsed.organization_id) do
            Database::RowLevelSecurity.apply!
            Internal::Models::ServiceIdentity.live
                                             .find_by(token_digest: Internal::ServiceToken.digest(parsed.secret))
          end
        end
      rescue Tenancy::Context::Conflict
        # The caller already had a different tenant open. That is a routing bug,
        # not a credential problem, and it must not be resolved by silently
        # authenticating against the wrong tenant.
        raise Failed, :tenant_context_conflict
      end
    end
  end
end
