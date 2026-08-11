# frozen_string_literal: true

require "rails_helper"

# INV-15 — authorization is deny-by-default and centrally evaluated.
#
# The examples are organized around the ways this component can be wrong, not
# around its methods. Each `describe` names a failure mode that would be a
# security defect rather than a bug.
RSpec.describe Nexus::Authorization::Authorize do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  describe "deny by default" do
    it "denies a principal holding no grants at all" do
      as_tenant(organization_id) do
        membership = create_membership!
        principal = human_principal(organization_id: organization_id, membership_id: membership)

        decision = decision_for(principal, :read, :workflows)

        expect(decision).to be_denied
        expect(decision.reason).to eq(:no_grant)
      end
    end

    it "denies a principal that is neither a membership nor a service identity" do
      as_tenant(organization_id) do
        principal = human_principal(organization_id: organization_id, membership_id: nil)

        expect(decision_for(principal, :read, :workflows)).to be_denied
      end
    end

    # A principal claiming both subject kinds is malformed. It must not be
    # resolved as "whichever one we checked first" — that is a grant-confusion
    # bug waiting to be reachable from a token parser.
    it "denies a principal claiming to be both a human and a service" do
      as_tenant(organization_id) do
        membership = create_membership!
        service = create_service_identity!
        assign_role!(role_key: "owner", membership_id: membership)

        principal = AuthorizationHelpers::Principal.new(
          organization_id: organization_id, membership_id: membership, service_identity_id: service
        )

        expect(decision_for(principal, :read, :workflows)).to be_denied
      end
    end
  end

  describe "an action that does not exist in the catalog" do
    # `:aprove` is the interesting case: a typo at a call site must never become
    # a permission, and must never be mistaken for one by a future prefix rule.
    it "denies a misspelled action rather than treating it as unrestricted" do
      as_tenant(organization_id) do
        membership = create_membership!
        assign_role!(role_key: "owner", membership_id: membership)
        principal = human_principal(organization_id: organization_id, membership_id: membership)

        decision = decision_for(principal, :aprove, :workflows)

        expect(decision).to be_denied
        expect(decision.reason).to eq(:undefined_permission)
      end
    end

    it "denies an unknown resource type even for an owner" do
      as_tenant(organization_id) do
        membership = create_membership!
        assign_role!(role_key: "owner", membership_id: membership)
        principal = human_principal(organization_id: organization_id, membership_id: membership)

        expect(decision_for(principal, :read, :nuclear_launch)).to be_denied
      end
    end
  end

  describe "role grants" do
    def principal_with(role_key)
      membership = create_membership!
      assign_role!(role_key: role_key, membership_id: membership)
      human_principal(organization_id: organization_id, membership_id: membership)
    end

    it "lets an owner perform a CRITICAL action" do
      as_tenant(organization_id) do
        expect(decision_for(principal_with("owner"), :manage, :roles)).to be_allowed
      end
    end

    it "stops an admin short of the authority-moving permissions" do
      as_tenant(organization_id) do
        admin = principal_with("admin")

        expect(decision_for(admin, :manage, :workflows)).to be_allowed
        expect(decision_for(admin, :manage, :roles)).to be_denied
        expect(decision_for(admin, :create, :grants)).to be_denied
      end
    end

    it "lets an operator run work but not reconfigure the platform" do
      as_tenant(organization_id) do
        operator = principal_with("operator")

        expect(decision_for(operator, :trigger, :workflows)).to be_allowed
        expect(decision_for(operator, :invoke, :agents)).to be_allowed
        expect(decision_for(operator, :register, :tools)).to be_denied
        expect(decision_for(operator, :manage, :workflows)).to be_denied
      end
    end

    it "confines a viewer to reads" do
      as_tenant(organization_id) do
        viewer = principal_with("viewer")

        expect(decision_for(viewer, :read, :workflows)).to be_allowed
        expect(decision_for(viewer, :trigger, :workflows)).to be_denied
        expect(decision_for(viewer, :ingest, :documents)).to be_denied
      end
    end

    it "applies to service identities on the same terms as humans" do
      as_tenant(organization_id) do
        service = create_service_identity!
        assign_role!(role_key: "viewer", service_identity_id: service)
        principal = service_principal(organization_id: organization_id, service_identity_id: service)

        expect(decision_for(principal, :read, :workflows)).to be_allowed
        expect(decision_for(principal, :trigger, :workflows)).to be_denied
      end
    end
  end

  describe "expiry" do
    # Evaluated with the database's clock. A worker whose clock is behind must
    # not be able to honor a grant the database considers dead.
    it "ignores a grant that has expired" do
      as_tenant(organization_id) do
        membership = create_membership!
        assign_role!(role_key: "owner", membership_id: membership, expires_at: 1.hour.ago)
        principal = human_principal(organization_id: organization_id, membership_id: membership)

        expect(decision_for(principal, :read, :workflows)).to be_denied
      end
    end

    it "honors a grant that has not expired yet" do
      as_tenant(organization_id) do
        membership = create_membership!
        assign_role!(role_key: "viewer", membership_id: membership, expires_at: 1.hour.from_now)
        principal = human_principal(organization_id: organization_id, membership_id: membership)

        expect(decision_for(principal, :read, :workflows)).to be_allowed
      end
    end
  end

  describe "conditional grants" do
    let(:principal) do
      membership = create_membership!
      assign_role!(role_key: "operator", membership_id: membership,
                   conditions: { "environment" => "staging" })
      human_principal(organization_id: organization_id, membership_id: membership)
    end

    it "applies when the condition is satisfied" do
      as_tenant(organization_id) do
        expect(decision_for(principal, :trigger, :workflows,
                            attributes: { "environment" => "staging" })).to be_allowed
      end
    end

    it "does not apply when the attribute has a different value" do
      as_tenant(organization_id) do
        expect(decision_for(principal, :trigger, :workflows,
                            attributes: { "environment" => "production" })).to be_denied
      end
    end

    # Silence is not consent. A caller that omits the attribute must not satisfy
    # a condition on it — otherwise every conditional grant is bypassed by
    # sending less information.
    it "does not apply when the attribute is simply absent" do
      as_tenant(organization_id) do
        expect(decision_for(principal, :trigger, :workflows)).to be_denied
      end
    end
  end

  describe "failing closed" do
    it "denies, rather than raising, when there is no tenant context" do
      principal = human_principal(organization_id: organization_id, membership_id: SecureRandom.uuid)

      decision = decision_for(principal, :read, :workflows)

      expect(decision).to be_denied
      expect(decision.reason).to eq(:evaluator_error)
    end

    # A principal from another tenant being evaluated against this tenant's
    # grants is a routing bug or an attack. Either way the answer is no.
    it "denies a principal belonging to a different tenant" do
      other_org = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")

      as_tenant(organization_id) do
        membership = create_membership!
        assign_role!(role_key: "owner", membership_id: membership)
        impostor = human_principal(organization_id: other_org, membership_id: membership)

        expect(decision_for(impostor, :read, :workflows)).to be_denied
      end
    end

    it "denies when the evaluator itself raises" do
      as_tenant(organization_id) do
        membership = create_membership!
        principal = human_principal(organization_id: organization_id, membership_id: membership)

        allow(Nexus::Authorization::PermissionSet)
          .to receive(:effective_for).and_raise(ActiveRecord::StatementInvalid, "connection lost")

        decision = decision_for(principal, :read, :workflows)

        expect(decision).to be_denied
        expect(decision.reason).to eq(:evaluator_error)
      end
    end
  end

  describe "tenant isolation of the decision itself" do
    it "does not let a grant in one tenant authorize anything in another" do
      other_org = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")

      membership_in_other = nil
      as_tenant(other_org) do
        membership_in_other = create_membership!
        assign_role!(role_key: "owner", membership_id: membership_in_other)
      end

      as_tenant(organization_id) do
        principal = human_principal(organization_id: organization_id, membership_id: membership_in_other)

        expect(decision_for(principal, :read, :workflows)).to be_denied
      end
    end
  end

  describe "#call!" do
    it "raises Denied with the reason rather than returning a decision" do
      as_tenant(organization_id) do
        membership = create_membership!
        principal = human_principal(organization_id: organization_id, membership_id: membership)

        expect { described_class.call!(principal, :read, :workflows) }
          .to raise_error(described_class::Denied, /no role held by this principal/)
      end
    end

    it "returns the decision when allowed" do
      as_tenant(organization_id) do
        membership = create_membership!
        assign_role!(role_key: "viewer", membership_id: membership)
        principal = human_principal(organization_id: organization_id, membership_id: membership)

        expect(described_class.call!(principal, :read, :workflows)).to be_allowed
      end
    end
  end
end
