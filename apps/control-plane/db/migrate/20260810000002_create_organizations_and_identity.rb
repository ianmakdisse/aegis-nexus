# frozen_string_literal: true

# Phase 3 — Organizations, Identity, Authorization.
#
# Ownership is declared in config/ownership.yml; boundary-check rejects any
# table here that no context claims (INV-13).
#
# Two structural decisions worth reading before changing anything:
#
#   * `organizations` is the tenant root and therefore does NOT carry an
#     organization_id of its own — it IS the organization. Its RLS policy keys
#     on `id` instead. Getting this wrong (adding a self-referential
#     organization_id) is a common and confusing mistake.
#
#   * `users` are global, `memberships` are tenant-scoped. A person may belong
#     to several organizations with different roles; modelling users as
#     tenant-scoped forces duplicate accounts and breaks SSO identity.
class CreateOrganizationsAndIdentity < ActiveRecord::Migration[7.1]
  def change
    # ---- Organizations (the tenant root) -----------------------------------
    create_table :organizations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :status, null: false, default: "active"   # active | suspended | closed

      # ADR-009 hybrid tenancy: where this tenant's data physically lives.
      t.string :tier, null: false, default: "pool"       # pool | dedicated
      t.string :region_code, null: false
      t.string :database_key                              # null on pool tier

      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end
    add_index :organizations, :slug, unique: true
    add_index :organizations, %i[tier region_code]
    add_foreign_key :organizations, :regions, column: :region_code, primary_key: :code

    # A dedicated-tier tenant without a database_key is unroutable; a pool-tier
    # tenant with one is ambiguous. Enforced in the database because the tenant
    # resolver treats this column as authoritative for connection routing.
    add_check_constraint :organizations,
                         "(tier = 'pool' AND database_key IS NULL) OR (tier = 'dedicated' AND database_key IS NOT NULL)",
                         name: "organizations_placement_consistent"

    # ---- Identity (global principals) --------------------------------------
    create_table :users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :email, null: false
      t.string :password_digest
      t.string :full_name
      t.string :status, null: false, default: "active"
      t.datetime :email_verified_at
      t.string :mfa_secret_ciphertext         # envelope-encrypted (INV-18)
      t.datetime :mfa_enabled_at
      t.datetime :last_authenticated_at
      t.timestamps
    end
    add_index :users, "lower(email)", unique: true, name: "index_users_on_lower_email"

    # Non-human principals (FR-106). Agents and services authenticate as
    # themselves so "the app did it" is never the answer in an audit.
    create_table :service_identities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :name, null: false
      t.string :kind, null: false                # service | agent
      t.string :token_digest, null: false
      t.jsonb :scopes, null: false, default: []
      t.datetime :expires_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :service_identities, %i[organization_id name], unique: true
    add_index :service_identities, :token_digest, unique: true
    add_foreign_key :service_identities, :organizations

    create_table :sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :user_id, null: false
      t.string :refresh_token_digest, null: false
      t.string :user_agent
      t.inet :ip_address
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      # Refresh-token reuse detection (FR-109): a rotated token presented again
      # means the token was stolen, so the whole family is revoked.
      t.uuid :family_id, null: false
      t.timestamps
    end
    add_index :sessions, :refresh_token_digest, unique: true
    add_index :sessions, %i[organization_id user_id]
    add_index :sessions, :family_id
    add_foreign_key :sessions, :organizations
    add_foreign_key :sessions, :users

    # ---- Memberships (the user ↔ tenant link) ------------------------------
    create_table :memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :user_id, null: false
      t.string :status, null: false, default: "active"
      t.datetime :invited_at
      t.datetime :accepted_at
      t.timestamps
    end
    add_index :memberships, %i[organization_id user_id], unique: true
    add_index :memberships, :user_id
    add_foreign_key :memberships, :organizations
    add_foreign_key :memberships, :users

    create_table :teams, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :name, null: false
      t.timestamps
    end
    add_index :teams, %i[organization_id name], unique: true
    add_foreign_key :teams, :organizations

    create_table :team_memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :team_id, null: false
      t.uuid :membership_id, null: false
      t.timestamps
    end
    add_index :team_memberships, %i[team_id membership_id], unique: true
    add_index :team_memberships, :organization_id
    add_foreign_key :team_memberships, :organizations
    add_foreign_key :team_memberships, :teams
    add_foreign_key :team_memberships, :memberships

    # Tenant placement history — the audit trail for ADR-009 promotions.
    create_table :org_placements, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :from_tier
      t.string :to_tier, null: false
      t.string :from_database_key
      t.string :to_database_key
      t.string :status, null: false, default: "pending" # pending|replicating|frozen|complete|rolled_back
      t.datetime :started_at
      t.datetime :completed_at
      t.jsonb :verification, null: false, default: {}
      t.timestamps
    end
    add_index :org_placements, %i[organization_id created_at]
    add_foreign_key :org_placements, :organizations

    # ---- Authorization -----------------------------------------------------
    # Roles are tenant-scoped so a tenant can define its own; system roles are
    # seeded per tenant rather than shared, which keeps every authorization
    # query inside one tenant's rows (and therefore inside RLS).
    create_table :roles, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :key, null: false                # owner | admin | operator | viewer | custom
      t.string :name, null: false
      t.boolean :system, null: false, default: false
      t.timestamps
    end
    add_index :roles, %i[organization_id key], unique: true
    add_foreign_key :roles, :organizations

    create_table :permissions, id: false do |t|
      t.string :key, primary_key: true, null: false   # "workflows.trigger"
      t.string :resource_type, null: false
      t.string :action, null: false
      t.string :risk_tier, null: false, default: "LOW" # LOW | MEDIUM | HIGH
      t.string :description
      t.timestamps
    end

    create_table :role_permissions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :role_id, null: false
      t.string :permission_key, null: false
      t.timestamps
    end
    add_index :role_permissions, %i[role_id permission_key], unique: true
    add_index :role_permissions, :organization_id
    add_foreign_key :role_permissions, :organizations
    add_foreign_key :role_permissions, :roles
    add_foreign_key :role_permissions, :permissions, column: :permission_key, primary_key: :key

    # A grant binds a role to a principal (membership or service identity).
    # Exactly one of the two must be set — enforced below, because a grant with
    # neither is unreachable and a grant with both is ambiguous.
    create_table :grants, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :role_id, null: false
      t.uuid :membership_id
      t.uuid :service_identity_id
      t.jsonb :conditions, null: false, default: {}   # ABAC overlay (FR-107)
      t.datetime :expires_at
      t.timestamps
    end
    add_index :grants, %i[organization_id membership_id]
    add_index :grants, %i[organization_id service_identity_id]
    add_foreign_key :grants, :organizations
    add_foreign_key :grants, :roles
    add_foreign_key :grants, :memberships
    add_foreign_key :grants, :service_identities
    add_check_constraint :grants,
                         "(membership_id IS NOT NULL AND service_identity_id IS NULL) OR " \
                         "(membership_id IS NULL AND service_identity_id IS NOT NULL)",
                         name: "grants_exactly_one_subject"

    create_table :policies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :name, null: false
      t.string :effect, null: false, default: "deny"  # allow | deny (deny wins)
      t.jsonb :matcher, null: false, default: {}
      t.integer :priority, null: false, default: 100
      t.timestamps
    end
    add_index :policies, %i[organization_id priority]
    add_foreign_key :policies, :organizations
  end
end
