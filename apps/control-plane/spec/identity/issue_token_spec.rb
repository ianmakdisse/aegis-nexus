# frozen_string_literal: true

require "rails_helper"

# FR-109 — refresh rotation with reuse detection.
RSpec.describe Nexus::Identity::IssueToken do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }
  let(:user) { register_user! }

  def with_membership(status: "active")
    as_tenant(organization_id) { create_membership!(user_id: user.id, status: status) }
  end

  describe ".for_user" do
    it "issues an access token and a refresh token for a member" do
      with_membership

      result = described_class.for_user(user_id: user.id, organization_id: organization_id)

      expect(result.access_token).to be_present
      expect(result.refresh_token).to be_present
      expect(result.principal.membership_id).to be_present
      expect(result.principal.organization_id).to eq(organization_id)
      expect(result.access_expires_at).to be <= 15.minutes.from_now
    end

    # Authentication proves a person exists. It says nothing about whether they
    # belong to the organization they are asking for — and conflating the two is
    # how a valid login becomes access to somebody else's tenant.
    it "refuses a verified user who is not a member of the organization" do
      expect { described_class.for_user(user_id: user.id, organization_id: organization_id) }
        .to raise_error(described_class::Failed, /membership/)
    end

    it "refuses a member whose membership is not active" do
      with_membership(status: "suspended")

      expect { described_class.for_user(user_id: user.id, organization_id: organization_id) }
        .to raise_error(described_class::Failed, /membership/)
    end

    it "stores only a digest of the refresh token" do
      with_membership
      result = described_class.for_user(user_id: user.id, organization_id: organization_id)

      as_tenant(organization_id) do
        stored = Nexus::Identity::Internal::Models::Session.find(result.session_id)

        expect(stored.refresh_token_digest).not_to eq(result.refresh_token)
        expect(stored.refresh_token_digest).to eq(Digest::SHA256.hexdigest(result.refresh_token))
      end
    end

    it "produces a token that authenticates back to the same principal" do
      with_membership
      result = described_class.for_user(user_id: user.id, organization_id: organization_id)

      recovered = Nexus::Identity::Authenticate.bearer(result.access_token)

      expect(recovered).to eq(result.principal)
    end
  end

  describe ".refresh" do
    it "rotates: the new token works and the old one does not" do
      with_membership
      first = described_class.for_user(user_id: user.id, organization_id: organization_id)

      second = described_class.refresh(refresh_token: first.refresh_token,
                                       organization_id: organization_id)

      expect(second.refresh_token).not_to eq(first.refresh_token)
      expect(Nexus::Identity::Authenticate.bearer(second.access_token)).to be_a(Nexus::Identity::Principal)
    end

    it "keeps the rotated token in the same family" do
      with_membership
      first = described_class.for_user(user_id: user.id, organization_id: organization_id)
      second = described_class.refresh(refresh_token: first.refresh_token,
                                       organization_id: organization_id)

      as_tenant(organization_id) do
        sessions = Nexus::Identity::Internal::Models::Session
                   .where(id: [first.session_id, second.session_id])

        expect(sessions.map(&:family_id).uniq.size).to eq(1)
      end
    end

    it "rejects an unknown refresh token" do
      expect do
        described_class.refresh(refresh_token: "nonsense", organization_id: organization_id)
      end.to raise_error(described_class::Failed)
    end

    describe "reuse detection" do
      # A rotated token presented twice means two parties hold it and we cannot
      # tell which is the thief. Killing the family logs the legitimate user out
      # too — the correct bias when the alternative is leaving an attacker in.
      it "revokes the entire family when a rotated token is replayed" do
        with_membership
        first = described_class.for_user(user_id: user.id, organization_id: organization_id)
        second = described_class.refresh(refresh_token: first.refresh_token,
                                         organization_id: organization_id)

        expect do
          described_class.refresh(refresh_token: first.refresh_token, organization_id: organization_id)
        end.to raise_error(described_class::ReuseDetected)

        # The attacker's replay also killed the victim's current token.
        expect do
          described_class.refresh(refresh_token: second.refresh_token, organization_id: organization_id)
        end.to raise_error(described_class::ReuseDetected)
      end

      it "is a distinct error class, because it is a security event and not a bad request" do
        expect(described_class::ReuseDetected.ancestors).not_to include(described_class::Failed)
      end
    end

    it "rejects an expired refresh token" do
      with_membership
      result = described_class.for_user(user_id: user.id, organization_id: organization_id)

      as_tenant(organization_id) do
        Nexus::Identity::Internal::Models::Session
          .find(result.session_id).update!(expires_at: 1.minute.ago)
      end

      expect do
        described_class.refresh(refresh_token: result.refresh_token, organization_id: organization_id)
      end.to raise_error(described_class::Failed)
    end
  end

  describe "tenant isolation" do
    it "cannot find a session issued in another tenant" do
      other = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")
      with_membership
      result = described_class.for_user(user_id: user.id, organization_id: organization_id)

      expect do
        described_class.refresh(refresh_token: result.refresh_token, organization_id: other)
      end.to raise_error(described_class::Failed)
    end
  end

  describe Nexus::Identity::RevokeToken do
    it "ends a session so it can no longer be refreshed" do
      with_membership
      result = Nexus::Identity::IssueToken.for_user(user_id: user.id, organization_id: organization_id)

      expect(described_class.call(refresh_token: result.refresh_token,
                                  organization_id: organization_id)).to be(true)

      expect do
        Nexus::Identity::IssueToken.refresh(refresh_token: result.refresh_token,
                                            organization_id: organization_id)
      end.to raise_error(Nexus::Identity::IssueToken::ReuseDetected)
    end

    it "revokes every session a user holds in this tenant" do
      with_membership
      Nexus::Identity::IssueToken.for_user(user_id: user.id, organization_id: organization_id)
      Nexus::Identity::IssueToken.for_user(user_id: user.id, organization_id: organization_id)

      expect(described_class.all_for_user(user_id: user.id, organization_id: organization_id)).to eq(2)
    end

    # Revocation stops refresh; it does not invalidate an access token already in
    # the wild. This is ADR-011's accepted trade and on-call has to know it.
    it "does not invalidate an access token that was already issued" do
      with_membership
      result = Nexus::Identity::IssueToken.for_user(user_id: user.id, organization_id: organization_id)

      described_class.call(refresh_token: result.refresh_token, organization_id: organization_id)

      expect(Nexus::Identity::Authenticate.bearer(result.access_token))
        .to be_a(Nexus::Identity::Principal)
    end
  end
end
