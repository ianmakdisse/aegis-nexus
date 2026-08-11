# frozen_string_literal: true

require "rails_helper"

RSpec.describe "system roles and the permission catalog" do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  describe Nexus::Authorization::PermissionCatalog do
    it "is installed and idempotent" do
      expect(described_class).to be_installed

      before_count = described_class.keys.size
      expect(described_class.install!).to eq(before_count)
      expect(described_class.keys.size).to eq(before_count)
    end

    it "gives every permission a valid risk tier" do
      tiers = described_class.to_a.map { |p| p[:risk_tier] }.uniq

      expect(tiers).to all(be_in(Nexus::Authorization::Internal::Catalog::RISK_TIERS))
    end

    it "installs with no tenant context, because the catalog is not tenant data" do
      expect { described_class.install! }.not_to raise_error
    end
  end

  describe Nexus::Authorization::SeedSystemRoles do
    it "gives a freshly provisioned tenant its four roles, with permissions attached" do
      as_tenant(organization_id) do
        roles = Nexus::Authorization::Internal::Models::Role.all

        expect(roles.map(&:key)).to match_array(%w[owner admin operator viewer])
        expect(roles).to all(be_system)
        expect(roles.map { |r| r.permission_keys.size }).to all(be > 0)
      end
    end

    it "gives the owner every permission in the catalog" do
      as_tenant(organization_id) do
        owner = Nexus::Authorization::Internal::Models::Role.find_by(key: "owner")

        expect(owner.permission_keys).to match_array(Nexus::Authorization::PermissionCatalog.keys)
      end
    end

    it "gives the viewer only low-risk permissions" do
      as_tenant(organization_id) do
        viewer = Nexus::Authorization::Internal::Models::Role.find_by(key: "viewer")
        tiers = viewer.permission_keys.map { |k| Nexus::Authorization::Internal::Catalog.risk_tier(k) }

        expect(tiers.uniq).to eq(["LOW"])
      end
    end

    it "adds nothing on a second run" do
      as_tenant(organization_id) do
        before = Nexus::Authorization::Internal::Models::RolePermission.count

        described_class.call

        expect(Nexus::Authorization::Internal::Models::RolePermission.count).to eq(before)
      end
    end

    # Provisioning against an empty catalog would produce four roles that grant
    # nothing — including an owner locked out of their own organization. The
    # failure has to surface here, where the cause is still visible.
    it "refuses to run when the catalog is not installed" do
      allow(Nexus::Authorization::PermissionCatalog).to receive(:installed?).and_return(false)

      expect { provision_organization!(name: "Doomed", slug: "doomed-#{SecureRandom.hex(4)}") }
        .to raise_error(described_class::CatalogNotInstalled)
    end
  end

  describe Nexus::Authorization::AssignRole do
    it "requires an explicit authorizer" do
      as_tenant(organization_id) do
        membership = create_membership!

        expect { described_class.call(role_key: "viewer", membership_id: membership, authorized_by: nil) }
          .to raise_error(ArgumentError)
      end
    end

    it "denies a principal that does not hold grants.create" do
      as_tenant(organization_id) do
        admin_membership = create_membership!
        assign_role!(role_key: "admin", membership_id: admin_membership)
        admin = human_principal(organization_id: organization_id, membership_id: admin_membership)

        target = create_membership!

        expect { described_class.call(role_key: "viewer", membership_id: target, authorized_by: admin) }
          .to raise_error(Nexus::Authorization::Authorize::Denied)
      end
    end

    it "allows an owner to grant a role" do
      as_tenant(organization_id) do
        owner_membership = create_membership!
        assign_role!(role_key: "owner", membership_id: owner_membership)
        owner = human_principal(organization_id: organization_id, membership_id: owner_membership)

        target = create_membership!
        grant_id = described_class.call(role_key: "viewer", membership_id: target, authorized_by: owner)

        expect(grant_id).to be_present

        principal = human_principal(organization_id: organization_id, membership_id: target)
        expect(Nexus::Authorization::Authorize.call(principal, :read, :workflows)).to be_allowed
      end
    end

    it "rejects a grant naming both a membership and a service identity" do
      as_tenant(organization_id) do
        membership = create_membership!
        service = create_service_identity!

        expect do
          described_class.call(role_key: "viewer", membership_id: membership,
                               service_identity_id: service,
                               authorized_by: described_class::SYSTEM_BOOTSTRAP)
        end.to raise_error(described_class::Error, /exactly one subject/)
      end
    end

    it "rejects an unknown role" do
      as_tenant(organization_id) do
        membership = create_membership!

        expect do
          described_class.call(role_key: "superuser", membership_id: membership,
                               authorized_by: described_class::SYSTEM_BOOTSTRAP)
        end.to raise_error(described_class::UnknownRole)
      end
    end
  end
end
