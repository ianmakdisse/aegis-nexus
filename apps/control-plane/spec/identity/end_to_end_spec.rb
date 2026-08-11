# frozen_string_literal: true

require "rails_helper"

# The seam this whole phase existed to close: a human logs in with a password
# and the resulting credential is accepted by the authorization evaluator built
# in Phase 4, with the right authority and no more.
#
# Until this passed, `Authorize` could only be exercised from a console.
RSpec.describe "authentication reaching authorization" do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }
  let(:user) { register_user! }

  def member_with_role(role_key)
    as_tenant(organization_id) do
      membership = create_membership!(user_id: user.id)
      assign_role!(role_key: role_key, membership_id: membership)
    end
  end

  it "carries a viewer from password to a permitted read and a refused write" do
    member_with_role("viewer")

    credentials = log_in!(user, organization_id)
    principal = Nexus::Identity::Authenticate.bearer(credentials.access_token)

    as_tenant(organization_id) do
      expect(Nexus::Authorization::Authorize.call(principal, :read, :workflows)).to be_allowed
      expect(Nexus::Authorization::Authorize.call(principal, :trigger, :workflows)).to be_denied
    end
  end

  it "reflects a revoked grant on the very next request, while the token is still valid" do
    member_with_role("operator")
    credentials = log_in!(user, organization_id)
    principal = Nexus::Identity::Authenticate.bearer(credentials.access_token)

    as_tenant(organization_id) do
      expect(Nexus::Authorization::Authorize.call(principal, :trigger, :workflows)).to be_allowed

      # Revoke authority, not the session. ADR-011's central claim is that this
      # takes effect immediately even though the access token remains valid.
      Nexus::Authorization::Internal::Models::Grant.destroy_all

      expect(Nexus::Authorization::Authorize.call(principal, :trigger, :workflows)).to be_denied
    end

    # The token itself is still perfectly good. Identity did not change; authority did.
    expect(Nexus::Identity::Authenticate.bearer(credentials.access_token)).to be_a(Nexus::Identity::Principal)
  end

  # INV-16 with real credentials on both sides, rather than the struct doubles
  # the delegation spec uses.
  it "narrows an owner-level agent to the viewer who invoked it" do
    member_with_role("viewer")
    credentials = log_in!(user, organization_id)
    invoker = Nexus::Identity::Authenticate.bearer(credentials.access_token)

    agent_token = as_tenant(organization_id) do
      registered = register_service!(kind: "agent")
      assign_role!(role_key: "owner", service_identity_id: registered.service_identity_id)
      registered.token
    end

    agent = Nexus::Identity::Authenticate.bearer(agent_token).acting_on_behalf_of(invoker)

    as_tenant(organization_id) do
      expect(Nexus::Authorization::Authorize.call(agent, :read, :workflows)).to be_allowed
      expect(Nexus::Authorization::Authorize.call(agent, :manage, :roles)).to be_denied
    end
  end

  it "refuses a login for a tenant the user does not belong to" do
    other = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")
    member_with_role("owner")

    expect { log_in!(user, other) }.to raise_error(Nexus::Identity::IssueToken::Failed)
  end
end
