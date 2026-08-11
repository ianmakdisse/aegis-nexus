# frozen_string_literal: true

require "rails_helper"

# ADR-011 — the access token asserts identity and nothing else.
RSpec.describe Nexus::Identity::Internal::AccessToken do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }
  let(:principal) do
    Nexus::Identity::Principal.human(
      organization_id: organization_id, user_id: SecureRandom.uuid, membership_id: SecureRandom.uuid
    )
  end

  describe "what the token carries" do
    it "round-trips identity" do
      claims = described_class.verify(described_class.issue(principal: principal))

      expect(claims["sub"]).to eq(principal.user_id)
      expect(claims["org"]).to eq(principal.organization_id)
      expect(claims["mbr"]).to eq(principal.membership_id)
      expect(claims["knd"]).to eq("user")
    end

    # The load-bearing test of ADR-011. Permissions in a token cannot be revoked;
    # this is the guard against someone adding them to save a query.
    it "carries no authorization information whatsoever" do
      claims = described_class.verify(described_class.issue(principal: principal))

      expect(claims.keys).to all(be_in(described_class::CLAIMS))
      expect(claims.keys).not_to include("perms", "permissions", "roles", "role", "grants", "abilities")
    end

    it "expires within the FR-109 ceiling of 15 minutes" do
      now = Time.current
      claims = described_class.verify(described_class.issue(principal: principal, now: now))

      expect(claims["exp"] - claims["iat"]).to be <= 15 * 60
    end

    it "names its audience and issuer explicitly" do
      claims = described_class.verify(described_class.issue(principal: principal))

      expect(claims["aud"]).to eq(described_class::AUDIENCE)
      expect(claims["iss"]).to eq(described_class::ISSUER)
    end

    it "gives each token a distinct id, so one can be traced without the others" do
      a = described_class.verify(described_class.issue(principal: principal))
      b = described_class.verify(described_class.issue(principal: principal))

      expect(a["jti"]).not_to eq(b["jti"])
    end
  end

  describe "rejecting bad tokens" do
    it "rejects an expired token" do
      token = described_class.issue(principal: principal, now: 20.minutes.ago)

      expect { described_class.verify(token) }.to raise_error(described_class::Invalid)
    end

    it "rejects a token that is not yet valid" do
      token = described_class.issue(principal: principal, now: 10.minutes.from_now)

      expect { described_class.verify(token) }.to raise_error(described_class::Invalid)
    end

    it "rejects a tampered payload" do
      token = described_class.issue(principal: principal)
      header, payload, signature = token.split(".")
      claims = JSON.parse(Base64.urlsafe_decode64(payload + "=" * (-payload.size % 4)))
      claims["org"] = SecureRandom.uuid
      forged = [header, Base64.urlsafe_encode64(claims.to_json, padding: false), signature].join(".")

      expect { described_class.verify(forged) }.to raise_error(described_class::Invalid)
    end

    # The `alg: none` attack: a verifier that trusts the token's own header can
    # be told not to check the signature. The algorithm allowlist is why this
    # fails, and this test is why nobody removes it.
    #
    # The forged header carries a VALID `kid` on purpose. Without it the token is
    # rejected at key lookup, which passes the test while proving nothing about
    # the allowlist — the first version of this example did exactly that, and
    # survived a mutation that added "none" to the permitted algorithms.
    it "rejects an unsigned token claiming alg=none" do
      claims = {
        "iss" => described_class::ISSUER, "aud" => described_class::AUDIENCE,
        "sub" => SecureRandom.uuid, "org" => organization_id, "mbr" => SecureRandom.uuid,
        "knd" => "user", "scp" => [], "jti" => SecureRandom.uuid,
        "iat" => Time.current.to_i, "nbf" => Time.current.to_i, "exp" => 10.minutes.from_now.to_i
      }
      unsigned = JWT.encode(claims, nil, "none", { "kid" => described_class.current_kid })

      expect { described_class.verify(unsigned) }.to raise_error(described_class::Invalid)
    end

    it "rejects a token signed with a different key" do
      claims = { "iss" => described_class::ISSUER, "aud" => described_class::AUDIENCE,
                 "sub" => SecureRandom.uuid, "org" => organization_id, "mbr" => SecureRandom.uuid,
                 "knd" => "user", "scp" => [], "jti" => SecureRandom.uuid,
                 "iat" => Time.current.to_i, "nbf" => Time.current.to_i,
                 "exp" => 10.minutes.from_now.to_i }
      forged = JWT.encode(claims, "an-attacker-chosen-key", "HS256",
                          { "kid" => described_class.current_kid })

      expect { described_class.verify(forged) }.to raise_error(described_class::Invalid)
    end

    it "rejects a token signed with an unknown key id" do
      claims = { "iss" => described_class::ISSUER, "aud" => described_class::AUDIENCE,
                 "sub" => SecureRandom.uuid, "org" => organization_id, "mbr" => SecureRandom.uuid,
                 "knd" => "user", "scp" => [], "jti" => SecureRandom.uuid,
                 "iat" => Time.current.to_i, "nbf" => Time.current.to_i,
                 "exp" => 10.minutes.from_now.to_i }
      forged = JWT.encode(claims, "other", "HS256", { "kid" => "deadbeefdeadbeef" })

      expect { described_class.verify(forged) }.to raise_error(described_class::Invalid)
    end

    it "rejects a token minted for a different audience" do
      claims = { "iss" => described_class::ISSUER, "aud" => "some-other-service",
                 "sub" => SecureRandom.uuid, "org" => organization_id, "mbr" => SecureRandom.uuid,
                 "knd" => "user", "scp" => [], "jti" => SecureRandom.uuid,
                 "iat" => Time.current.to_i, "nbf" => Time.current.to_i,
                 "exp" => 10.minutes.from_now.to_i }
      other = JWT.encode(claims, described_class.current_key, "HS256",
                         { "kid" => described_class.current_kid })

      expect { described_class.verify(other) }.to raise_error(described_class::Invalid)
    end

    # A token from a future version carrying a claim this version does not
    # understand is rejected rather than partially trusted.
    it "rejects unrecognized claims" do
      claims = { "iss" => described_class::ISSUER, "aud" => described_class::AUDIENCE,
                 "sub" => SecureRandom.uuid, "org" => organization_id, "mbr" => SecureRandom.uuid,
                 "knd" => "user", "scp" => [], "jti" => SecureRandom.uuid,
                 "iat" => Time.current.to_i, "nbf" => Time.current.to_i,
                 "exp" => 10.minutes.from_now.to_i, "perms" => ["roles.manage"] }
      smuggled = JWT.encode(claims, described_class.current_key, "HS256",
                            { "kid" => described_class.current_kid })

      expect { described_class.verify(smuggled) }.to raise_error(described_class::Invalid)
    end

    # Verification is detailed internally — on-call needs to know whether a key
    # is unknown or a clock is skewed. The uniformity guarantee lives one layer
    # up, at the published contract, which is the only surface a caller sees.
    it "collapses to one indistinguishable failure at the published contract" do
      expired = bearer_failure(described_class.issue(principal: principal, now: 20.minutes.ago))
      unknown_key = bearer_failure(
        JWT.encode({ "sub" => "x" }, "k", "HS256", { "kid" => "0000000000000000" })
      )

      expect(expired.message).to eq(unknown_key.message)
      expect(expired.message).not_to match(/expired|key|kid/i)
    end
  end

  def bearer_failure(token)
    Nexus::Identity::Authenticate.bearer(token)
    raise "expected authentication to fail"
  rescue Nexus::Identity::Authenticate::Failed => e
    e
  end
end
