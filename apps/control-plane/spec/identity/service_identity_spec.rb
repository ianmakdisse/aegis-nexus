# frozen_string_literal: true

require "rails_helper"

# FR-106 — services and agents are first-class principals with their own
# credentials, so that "the app did it" is never the audit answer.
RSpec.describe Nexus::Identity::RegisterServiceIdentity do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  describe "registration" do
    it "returns the credential exactly once and stores only its digest" do
      result = as_tenant(organization_id) { register_service! }

      as_tenant(organization_id) do
        row = Nexus::Identity::Internal::Models::ServiceIdentity.find(result.service_identity_id)

        expect(result.token).to be_present
        expect(row.token_digest).not_to eq(result.token)
        expect(row.attributes.values.map(&:to_s)).not_to include(result.token)
      end
    end

    it "names its tenant in the credential, so authentication never runs unscoped" do
      result = as_tenant(organization_id) { register_service! }
      parsed = Nexus::Identity::Internal::ServiceToken.parse(result.token)

      expect(parsed.organization_id).to eq(organization_id)
    end

    it "grants no authority on its own" do
      result = as_tenant(organization_id) { register_service! }
      principal = Nexus::Identity::Authenticate.bearer(result.token)

      as_tenant(organization_id) do
        expect(Nexus::Authorization::Authorize.call(principal, :read, :workflows)).to be_denied
      end
    end

    it "rejects a duplicate name within the tenant" do
      as_tenant(organization_id) do
        register_service!(name: "deployer")

        expect { register_service!(name: "deployer") }.to raise_error(described_class::Error)
      end
    end
  end

  describe "authenticating with the credential" do
    it "resolves to a machine principal" do
      result = as_tenant(organization_id) { register_service!(kind: "agent", scopes: ["workflows:run"]) }

      principal = Nexus::Identity::Authenticate.bearer(result.token)

      expect(principal).to be_machine
      expect(principal.kind).to eq("agent")
      expect(principal.service_identity_id).to eq(result.service_identity_id)
      expect(principal.organization_id).to eq(organization_id)
      expect(principal.scopes).to eq(["workflows:run"])
    end

    it "works once a role has been granted" do
      result = as_tenant(organization_id) { register_service!(kind: "agent") }
      as_tenant(organization_id) do
        assign_role!(role_key: "viewer", service_identity_id: result.service_identity_id)
      end

      principal = Nexus::Identity::Authenticate.bearer(result.token)

      as_tenant(organization_id) do
        expect(Nexus::Authorization::Authorize.call(principal, :read, :workflows)).to be_allowed
        expect(Nexus::Authorization::Authorize.call(principal, :trigger, :workflows)).to be_denied
      end
    end

    it "rejects a token whose secret has been altered" do
      result = as_tenant(organization_id) { register_service! }
      tampered = "#{result.token}x"

      expect { Nexus::Identity::Authenticate.bearer(tampered) }
        .to raise_error(Nexus::Identity::Authenticate::Failed)
    end

    it "rejects a revoked identity" do
      result = as_tenant(organization_id) { register_service! }
      as_tenant(organization_id) do
        Nexus::Identity::Internal::Models::ServiceIdentity
          .find(result.service_identity_id).update!(revoked_at: Time.current)
      end

      expect { Nexus::Identity::Authenticate.bearer(result.token) }
        .to raise_error(Nexus::Identity::Authenticate::Failed)
    end

    it "rejects an expired identity" do
      result = as_tenant(organization_id) { register_service!(expires_at: 1.hour.from_now) }
      as_tenant(organization_id) do
        Nexus::Identity::Internal::Models::ServiceIdentity
          .find(result.service_identity_id).update!(expires_at: 1.hour.ago)
      end

      expect { Nexus::Identity::Authenticate.bearer(result.token) }
        .to raise_error(Nexus::Identity::Authenticate::Failed)
    end
  end

  describe "the tenant segment is routing, not authority" do
    # Forging it opens a context in which the presented secret matches nothing.
    # The point of the test is that it fails *closed*, not that it is trusted.
    it "does not authenticate when the tenant segment is swapped for another tenant" do
      other = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")
      result = as_tenant(organization_id) { register_service! }
      _prefix, _tenant, secret = result.token.split("_", 3)
      forged = ["nxs", other.delete("-"), secret].join("_")

      expect { Nexus::Identity::Authenticate.bearer(forged) }
        .to raise_error(Nexus::Identity::Authenticate::Failed)
    end

    it "rejects a malformed tenant segment rather than querying with it" do
      result = as_tenant(organization_id) { register_service! }
      _prefix, _tenant, secret = result.token.split("_", 3)

      ["nxs_not-a-uuid_#{secret}", "nxs__#{secret}", "nxs_#{'f' * 31}_#{secret}"].each do |forged|
        expect { Nexus::Identity::Authenticate.bearer(forged) }
          .to raise_error(Nexus::Identity::Authenticate::Failed)
      end
    end
  end
end
