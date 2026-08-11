# frozen_string_literal: true

module Nexus
  module Identity
    module Internal
      # The wire format for machine credentials: `nxs_<tenant>_<secret>`.
      #
      # WHY THE TENANT IS IN THE TOKEN
      #
      # `service_identities` is RLS-protected, so a lookup by digest returns
      # nothing unless a tenant context is already open. But the whole point of
      # authenticating is that we do not yet know who is calling — and the
      # request flow resolves the tenant *after* the principal. That ordering
      # cannot hold for a bearer credential, so the credential carries its own
      # tenant and the lookup happens inside that tenant's context.
      #
      # This is not a security claim, it is a routing hint: the tenant segment is
      # attacker-controlled and grants nothing. Forging it opens a context in
      # which the presented secret simply does not match any row. What it buys is
      # that a stolen token cannot be used to probe other tenants, and that
      # authentication never runs with isolation disabled.
      #
      # The prefix also makes the credential greppable in logs and detectable by
      # secret scanners — a token that cannot be recognized as a token is one
      # nobody can find after it leaks.
      module ServiceToken
        PREFIX = "nxs"
        SEPARATOR = "_"

        Parsed = Struct.new(:organization_id, :secret, keyword_init: true)

        module_function

        def looks_like?(raw) = raw.to_s.start_with?("#{PREFIX}#{SEPARATOR}")

        # @return [String] the plaintext credential, returned exactly once
        def mint(organization_id:)
          [PREFIX, organization_id.to_s.delete("-"), TokenDigest.generate].join(SEPARATOR)
        end

        # @return [Parsed, nil] nil for anything malformed — a parse failure is
        #   an authentication failure, never an exception to be rescued upstream
        def parse(raw)
          return nil unless looks_like?(raw)

          _prefix, tenant, secret = raw.to_s.split(SEPARATOR, 3)
          return nil if tenant.blank? || secret.blank?

          organization_id = hyphenate(tenant)
          return nil if organization_id.nil?

          Parsed.new(organization_id: organization_id, secret: secret)
        end

        # The tenant segment is a UUID with the hyphens stripped. Rebuilding it
        # rather than accepting whatever was sent means a malformed segment can
        # never reach a query as a fragment of SQL or as a partial match.
        def hyphenate(compact)
          return nil unless compact.match?(/\A[0-9a-f]{32}\z/i)

          [compact[0, 8], compact[8, 4], compact[12, 4], compact[16, 4], compact[20, 12]].join("-")
        end

        # The digest stored on the row. Only the secret segment is hashed: the
        # tenant segment is public routing information, and including it would
        # make the digest depend on data that is already in the row.
        def digest(secret) = TokenDigest.digest(secret)
      end
    end
  end
end
