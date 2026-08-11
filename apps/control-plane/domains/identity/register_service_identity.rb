# frozen_string_literal: true

module Nexus
  module Identity
    # Published contract: create a machine principal (FR-106).
    #
    # Services and agents get their own identities because "the app did it" is
    # not an acceptable audit answer, and because a shared service account makes
    # least privilege impossible — everything that account can do, every caller
    # can do.
    #
    # The credential is returned **once**. Only its digest is stored, so there is
    # no "show me the token again" operation and there never will be: a system
    # that can re-display a credential is a system where a database read is a
    # credential theft.
    #
    # An identity created here holds no authority at all until a role is granted
    # to it through `Authorization::AssignRole`. Registration and authorization
    # are separate steps on purpose — creating an actor should not be a way to
    # create power.
    class RegisterServiceIdentity
      Error = Class.new(StandardError)

      Result = Struct.new(:service_identity_id, :name, :kind, :token, keyword_init: true)

      def self.call(...) = new.call(...)

      # Must run inside the target tenant's context — a machine identity belongs
      # to exactly one organization, and RLS rejects it otherwise.
      #
      # @param kind [String] "service" or "agent" (INV-16 treats agents' authority
      #   as always narrowed by their invoker; the distinction is recorded here)
      # @param expires_at [Time, nil] nil means no expiry, which should be rare
      #   and is worth a review comment wherever it appears
      def call(name:, kind: "service", expires_at: nil, scopes: [])
        organization_id = Tenancy::Context.organization_id
        token = Internal::ServiceToken.mint(organization_id: organization_id)
        parsed = Internal::ServiceToken.parse(token)

        identity = Internal::Models::ServiceIdentity.new(
          name: name,
          kind: kind.to_s,
          token_digest: Internal::ServiceToken.digest(parsed.secret),
          scopes: Array(scopes),
          expires_at: expires_at
        )

        raise Error, "could not register: #{identity.errors.full_messages.join(', ')}" unless identity.save

        Result.new(service_identity_id: identity.id, name: identity.name,
                   kind: identity.kind, token: token)
      end
    end
  end
end
