# frozen_string_literal: true

module Nexus
  module Identity
    # Published contract: end sessions.
    #
    # WHAT REVOCATION DOES AND DOES NOT DO — read this before using it in an
    # incident.
    #
    # Revoking a session stops **refresh**. It does not invalidate an access
    # token that has already been issued: those are verified statelessly and
    # remain valid until they expire, ≤ 15 minutes (ADR-011). So revocation has a
    # bounded latency, and it is not zero.
    #
    # To stop a principal *right now*, revoke their authority, not their session:
    # authorization is evaluated against live state on every request, so removing
    # a grant takes effect on the next call. This is the single most important
    # operational fact about the authentication design, and the reason it is
    # written here rather than only in a runbook is that this is the file someone
    # opens at 3am looking for a kill switch.
    class RevokeToken
      class << self
        def call(...) = new.call(...)
        def family(...) = new.family(...)
        def all_for_user(...) = new.all_for_user(...)
      end

      # Revoke exactly one session, identified by the refresh token itself.
      # This is ordinary logout.
      #
      # @return [Boolean] whether a live session was found and revoked
      def call(refresh_token:, organization_id:)
        within_tenant(organization_id) do
          session = Internal::Models::Session.find_by(
            refresh_token_digest: Internal::TokenDigest.digest(refresh_token)
          )
          next false if session.nil? || session.revoked?

          session.revoke!
          true
        end
      end

      # Revoke every session descended from one login. This is what reuse
      # detection triggers, and what "log me out of this device everywhere it has
      # been rotated" means.
      def family(family_id:, organization_id:)
        within_tenant(organization_id) do
          sessions = Internal::Models::Session.in_family(family_id).where(revoked_at: nil).to_a
          sessions.each(&:revoke!)
          sessions.size
        end
      end

      # Every session a user holds in this tenant. Note the scope: a user who
      # belongs to three organizations keeps their sessions in the other two,
      # because those are different grants of authority and revoking them is a
      # different decision made by different administrators.
      def all_for_user(user_id:, organization_id:)
        within_tenant(organization_id) do
          sessions = Internal::Models::Session.where(user_id: user_id, revoked_at: nil).to_a
          sessions.each(&:revoke!)
          sessions.size
        end
      end

      private

      def within_tenant(organization_id, &block)
        ActiveRecord::Base.transaction(requires_new: true) do
          Tenancy::Context.with(organization_id: organization_id) do
            Database::RowLevelSecurity.apply!
            block.call
          end
        end
      end
    end
  end
end
