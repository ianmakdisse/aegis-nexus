# frozen_string_literal: true

require "rails_helper"

# INV-16 — delegated authority only narrows.
#
# This is the invariant that keeps the agent runtime from becoming a universal
# privilege-escalation device. If it fails, an attacker who can influence an
# agent's input inherits whatever that agent's own identity holds — which is
# usually a great deal more than the person who invoked it.
RSpec.describe Nexus::Authorization::PermissionSet do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  describe "an agent acting for a user" do
    it "reduces an owner-level agent to its viewer invoker's authority" do
      as_tenant(organization_id) do
        invoker = create_membership!
        assign_role!(role_key: "viewer", membership_id: invoker)

        agent = create_service_identity!
        assign_role!(role_key: "owner", service_identity_id: agent)

        acting = service_principal(
          organization_id: organization_id,
          service_identity_id: agent,
          acting_for: human_principal(organization_id: organization_id, membership_id: invoker)
        )

        # The agent alone could do this; acting for a viewer, it cannot.
        expect(Nexus::Authorization::Authorize.call(acting, :trigger, :workflows)).to be_denied
        expect(Nexus::Authorization::Authorize.call(acting, :read, :workflows)).to be_allowed
      end
    end

    it "is bounded by the agent as well as by the invoker" do
      as_tenant(organization_id) do
        invoker = create_membership!
        assign_role!(role_key: "owner", membership_id: invoker)

        agent = create_service_identity!
        assign_role!(role_key: "viewer", service_identity_id: agent)

        acting = service_principal(
          organization_id: organization_id,
          service_identity_id: agent,
          acting_for: human_principal(organization_id: organization_id, membership_id: invoker)
        )

        # An owner invoking a read-only agent does not lend it their authority.
        expect(Nexus::Authorization::Authorize.call(acting, :trigger, :workflows)).to be_denied
      end
    end

    it "yields nothing when the invoker holds nothing" do
      as_tenant(organization_id) do
        invoker = create_membership!

        agent = create_service_identity!
        assign_role!(role_key: "owner", service_identity_id: agent)

        acting = service_principal(
          organization_id: organization_id,
          service_identity_id: agent,
          acting_for: human_principal(organization_id: organization_id, membership_id: invoker)
        )

        expect(described_class.effective_for(acting)).to be_empty
      end
    end
  end

  describe "chains" do
    it "narrows at every hop" do
      as_tenant(organization_id) do
        human = create_membership!
        assign_role!(role_key: "operator", membership_id: human)

        outer_agent = create_service_identity!
        assign_role!(role_key: "owner", service_identity_id: outer_agent)

        inner_agent = create_service_identity!
        assign_role!(role_key: "owner", service_identity_id: inner_agent)

        chain = service_principal(
          organization_id: organization_id,
          service_identity_id: inner_agent,
          acting_for: service_principal(
            organization_id: organization_id,
            service_identity_id: outer_agent,
            acting_for: human_principal(organization_id: organization_id, membership_id: human)
          )
        )

        effective = described_class.effective_for(chain)

        expect(effective.include?("workflows.trigger")).to be(true)
        expect(effective.include?("roles.manage")).to be(false)
      end
    end

    # A delegation cycle inside an authorization check is an infinite loop in the
    # one component every request waits on — a denial of service, not a mere bug.
    it "refuses to follow a cycle, and the caller sees a denial" do
      as_tenant(organization_id) do
        membership = create_membership!
        assign_role!(role_key: "owner", membership_id: membership)

        principal = human_principal(organization_id: organization_id, membership_id: membership)
        principal.acting_for = principal

        expect { described_class.effective_for(principal) }
          .to raise_error(described_class::DelegationTooDeep)

        decision = Nexus::Authorization::Authorize.call(principal, :read, :workflows)
        expect(decision).to be_denied
        expect(decision.reason).to eq(:evaluator_error)
      end
    end
  end

  describe "set algebra" do
    it "never grows a set" do
      a = described_class.new(%w[workflows.read workflows.trigger])
      b = described_class.new(%w[workflows.read agents.invoke])

      expect(a.intersect(b).to_a).to eq(%w[workflows.read])
      expect(b.intersect(a).to_a).to eq(%w[workflows.read])
    end

    it "is immutable once built" do
      set = described_class.new(%w[workflows.read])

      expect(set).to be_frozen
      expect { set.keys << "roles.manage" }.to raise_error(FrozenError)
    end
  end
end
