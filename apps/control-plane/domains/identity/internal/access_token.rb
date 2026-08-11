# frozen_string_literal: true

require "jwt"

module Nexus
  module Identity
    module Internal
      # The short-lived access token (ADR-011, FR-109).
      #
      # WHAT IS NOT IN HERE
      #
      # Roles. Permissions. Scopes that imply either. The token asserts *who* the
      # caller is and nothing about what they may do — that question is answered
      # per request by Authorization::Authorize against live database state, so
      # that a revoked permission is revoked now rather than in ≤ 15 minutes.
      # `CLAIMS` is enforced by a test for exactly this reason: the failure this
      # guards against is somebody adding `perms` to save a query.
      #
      # `scp` is the exception that proves the rule. It narrows what a token may
      # be used for (a delegation ceiling), it can never widen anything, and it is
      # intersected with the principal's real permissions like any other
      # narrowing input (INV-16).
      class AccessToken
        Invalid = Class.new(StandardError)

        ALGORITHM = "HS256"
        ISSUER = "aegis-nexus"
        AUDIENCE = "aegis-nexus.api"
        LIFETIME = 15.minutes           # FR-109 ceiling, not a default to tune upward
        LEEWAY = 5.seconds              # clock skew tolerance; see ADR-011 failure modes

        # The complete claim vocabulary. A claim not listed here is rejected on
        # verification rather than ignored, so a token minted by a future version
        # cannot smuggle a field this version does not understand.
        CLAIMS = %w[iss aud sub org mbr knd scp jti iat nbf exp].freeze

        class << self
          def issue(principal:, scopes: [], now: Time.current)
            payload = {
              "iss" => ISSUER,
              "aud" => AUDIENCE,
              "sub" => principal.subject_id,
              "org" => principal.organization_id,
              "mbr" => principal.membership_id,
              "knd" => principal.kind,
              "scp" => Array(scopes),
              # The principal's token id IS the jti when it has one. Minting a
              # separate id here would mean the Principal a caller holds and the
              # Principal that token authenticates back to are not equal — a
              # difference that shows up first in an audit trail nobody can
              # reconcile.
              "jti" => principal.token_id.presence || SecureRandom.uuid,
              "iat" => now.to_i,
              "nbf" => now.to_i,
              "exp" => (now + LIFETIME).to_i
            }

            JWT.encode(payload, current_key, ALGORITHM, { "kid" => current_kid })
          end

          # @return [Hash] the verified claims
          # @raise [Invalid] for every failure, with no detail about which one —
          #   a verifier that explains *why* a token is bad is an oracle.
          def verify(token)
            claims, header = JWT.decode(
              token, nil, true,
              algorithms: [ALGORITHM],          # never trust the header's `alg` (the `none` attack)
              iss: ISSUER, verify_iss: true,
              aud: AUDIENCE, verify_aud: true,
              verify_expiration: true, verify_not_before: true,
              leeway: LEEWAY.to_i
            ) { |hdr| key_for(hdr["kid"]) }

            unexpected = claims.keys - CLAIMS
            raise Invalid, "unrecognized claims" if unexpected.any?
            raise Invalid, "missing subject" if claims["sub"].blank? || claims["org"].blank?

            claims
          rescue JWT::DecodeError, JWT::VerificationError => e
            raise Invalid, "token rejected (#{e.class})"
          end

          # Key material. Phase 13 moves this to the secrets manager chosen by
          # unresolved question Q1; until then it is derived from the
          # application's own secret so that no environment runs with a token key
          # that is weaker than its cookie key, and none needs extra setup to
          # boot. The `kid` indirection exists now, unused, so that rotating
          # later does not invalidate tokens already in flight.
          def current_key
            @current_key ||= ENV["NEXUS_TOKEN_SIGNING_KEY"].presence || derived_key
          end

          def current_kid = kid_for(current_key)

          def previous_key = ENV["NEXUS_TOKEN_SIGNING_KEY_PREVIOUS"].presence

          def key_for(kid)
            ring = { current_kid => current_key }
            ring[kid_for(previous_key)] = previous_key if previous_key

            ring.fetch(kid) { raise Invalid, "unknown signing key" }
          end

          # Test hook: the derived key is memoized, and the suite needs to be able
          # to forget it after changing the environment.
          def reset_keys!
            @current_key = nil
          end

          private

          def kid_for(key) = Digest::SHA256.hexdigest(key.to_s)[0, 16]

          def derived_key
            Rails.application.key_generator.generate_key("nexus/identity/access-token", 32)
          end
        end
      end
    end
  end
end
