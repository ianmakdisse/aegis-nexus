# frozen_string_literal: true

require "rails_helper"

# The ABAC overlay (FR-107). Its one structural property: a policy can only ever
# take authority away. Everything else here is precedence detail.
RSpec.describe Nexus::Authorization::Policy do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  def operator_principal
    membership = create_membership!
    assign_role!(role_key: "operator", membership_id: membership)
    human_principal(organization_id: organization_id, membership_id: membership)
  end

  describe "policies never widen authority" do
    it "cannot grant a viewer a permission its roles do not carry" do
      as_tenant(organization_id) do
        membership = create_membership!
        assign_role!(role_key: "viewer", membership_id: membership)
        viewer = human_principal(organization_id: organization_id, membership_id: membership)

        create_policy!(name: "let viewers trigger", effect: "allow",
                       matcher: { "permissions" => ["workflows.trigger"] }, priority: 1)

        decision = decision_for(viewer, :trigger, :workflows)

        expect(decision).to be_denied
        expect(decision.reason).to eq(:no_grant)
      end
    end
  end

  describe "deny" do
    it "removes a permission the principal's role does carry" do
      as_tenant(organization_id) do
        operator = operator_principal
        expect(decision_for(operator, :trigger, :workflows)).to be_allowed

        create_policy!(name: "freeze workflows", effect: "deny",
                       matcher: { "permissions" => ["workflows.trigger"] })

        decision = decision_for(operator, :trigger, :workflows)
        expect(decision).to be_denied
        expect(decision.reason).to eq(:policy_denied)
      end
    end

    it "can be scoped by risk tier rather than by naming every permission" do
      as_tenant(organization_id) do
        operator = operator_principal

        create_policy!(name: "no high-risk actions", effect: "deny",
                       matcher: { "risk_tiers" => %w[HIGH CRITICAL] })

        expect(decision_for(operator, :trigger, :workflows)).to be_denied
        expect(decision_for(operator, :read, :workflows)).to be_allowed
      end
    end

    it "can be scoped by request attributes" do
      as_tenant(organization_id) do
        operator = operator_principal

        create_policy!(name: "no production integration calls", effect: "deny",
                       matcher: { "resource_types" => ["integrations"],
                                  "attributes" => { "environment" => "production" } })

        expect(decision_for(operator, :call, :integrations,
                            attributes: { "environment" => "production" })).to be_denied
        expect(decision_for(operator, :call, :integrations,
                            attributes: { "environment" => "staging" })).to be_allowed
      end
    end

    # An empty matcher names nothing, and a clause that names nothing means
    # "any". This is a tenant-wide lockout, and the test exists so that nobody
    # discovers that property in production.
    it "matches everything when the matcher is empty" do
      as_tenant(organization_id) do
        operator = operator_principal

        create_policy!(name: "lockdown", effect: "deny", matcher: {})

        expect(decision_for(operator, :read, :workflows)).to be_denied
      end
    end
  end

  describe "precedence" do
    it "lets a lower-priority-number allow carve an exception out of a broad deny" do
      as_tenant(organization_id) do
        operator = operator_principal

        create_policy!(name: "no high-risk actions", effect: "deny",
                       matcher: { "risk_tiers" => %w[HIGH CRITICAL] }, priority: 100)
        create_policy!(name: "except the nightly reconciliation", effect: "allow",
                       matcher: { "permissions" => ["workflows.trigger"],
                                  "attributes" => { "definition_key" => "nightly_reconciliation" } },
                       priority: 10)

        expect(decision_for(operator, :trigger, :workflows,
                            attributes: { "definition_key" => "nightly_reconciliation" })).to be_allowed
        expect(decision_for(operator, :trigger, :workflows,
                            attributes: { "definition_key" => "issue_refund" })).to be_denied
      end
    end

    it "does not let a higher-priority-number allow override a deny" do
      as_tenant(organization_id) do
        operator = operator_principal

        create_policy!(name: "freeze", effect: "deny",
                       matcher: { "permissions" => ["workflows.trigger"] }, priority: 10)
        create_policy!(name: "unfreeze", effect: "allow",
                       matcher: { "permissions" => ["workflows.trigger"] }, priority: 50)

        expect(decision_for(operator, :trigger, :workflows)).to be_denied
      end
    end
  end

  describe "fail-closed matching" do
    # A policy written against a future version of the evaluator must degrade to
    # "more restrictive", never to "unenforced". Both effects fail closed, in
    # opposite directions.
    it "treats a deny policy with an unrecognized clause as matching" do
      policy = described_class.new(id: "x", name: "future syntax", effect: "deny",
                                   matcher: { "geo_fence" => ["EU"] }, priority: 1)

      expect(policy.matches?(request_for("workflows.trigger"))).to be(true)
    end

    it "treats an allow policy with an unrecognized clause as not matching" do
      policy = described_class.new(id: "x", name: "future syntax", effect: "allow",
                                   matcher: { "geo_fence" => ["EU"] }, priority: 1)

      expect(policy.matches?(request_for("workflows.trigger"))).to be(false)
    end

    it "treats an unreadable matcher the same way" do
      deny = described_class.new(id: "x", name: "corrupt", effect: "deny", matcher: "not a hash", priority: 1)
      allow = described_class.new(id: "y", name: "corrupt", effect: "allow", matcher: nil, priority: 1)

      expect(deny.matches?(request_for("workflows.trigger"))).to be(true)
      expect(allow.matches?(request_for("workflows.trigger"))).to be(false)
    end
  end

  def request_for(permission_key)
    resource_type, action = permission_key.split(".")
    described_class::Request.new(permission_key: permission_key, resource_type: resource_type,
                                 action: action, risk_tier: "HIGH", attributes: {})
  end
end
