# frozen_string_literal: true

module AuthorizationHelpers
  # A stand-in for Identity::Principal, which does not exist yet (Phase 3
  # remainder). Authorization deliberately does not name that constant — it
  # accepts anything carrying a tenant and exactly one subject id — so this
  # struct is not a mock of a collaborator, it *is* the contract being tested.
  Principal = Struct.new(:organization_id, :membership_id, :service_identity_id, :acting_for,
                         keyword_init: true)

  def human_principal(organization_id:, membership_id:, acting_for: nil)
    Principal.new(organization_id: organization_id, membership_id: membership_id,
                  acting_for: acting_for)
  end

  def service_principal(organization_id:, service_identity_id:, acting_for: nil)
    Principal.new(organization_id: organization_id, service_identity_id: service_identity_id,
                  acting_for: acting_for)
  end

  # Memberships belong to Organizations and service identities to Identity;
  # neither context has a published contract for creating them yet. Tests write
  # the rows directly rather than reaching into another context's models — the
  # row shape is what these specs depend on, and it is visible here.
  #
  # Must run inside `as_tenant`: both tables are RLS-protected, and an insert
  # without the session variable set is rejected by the database.
  def create_membership!(user_id: nil, user_email: "member-#{SecureRandom.hex(4)}@example.com", status: "active")
    user_id ||= create_user!(email: user_email)
    conn = ActiveRecord::Base.connection
    conn.select_value(<<~SQL.squish)
      INSERT INTO memberships (organization_id, user_id, status, created_at, updated_at)
      VALUES (#{conn.quote(Nexus::Tenancy::Context.organization_id)}, #{conn.quote(user_id)},
              #{conn.quote(status)}, now(), now())
      RETURNING id
    SQL
  end

  def create_service_identity!(name: "svc-#{SecureRandom.hex(4)}", kind: "agent")
    conn = ActiveRecord::Base.connection
    conn.select_value(<<~SQL.squish)
      INSERT INTO service_identities (organization_id, name, kind, token_digest, created_at, updated_at)
      VALUES (#{conn.quote(Nexus::Tenancy::Context.organization_id)}, #{conn.quote(name)},
              #{conn.quote(kind)}, #{conn.quote(SecureRandom.hex(32))}, now(), now())
      RETURNING id
    SQL
  end

  def assign_role!(role_key:, membership_id: nil, service_identity_id: nil, **options)
    Nexus::Authorization::AssignRole.call(
      role_key: role_key,
      membership_id: membership_id,
      service_identity_id: service_identity_id,
      authorized_by: Nexus::Authorization::AssignRole::SYSTEM_BOOTSTRAP,
      **options
    )
  end

  def create_policy!(name:, effect:, matcher:, priority: 100)
    conn = ActiveRecord::Base.connection
    conn.select_value(<<~SQL.squish)
      INSERT INTO policies (organization_id, name, effect, matcher, priority, created_at, updated_at)
      VALUES (#{conn.quote(Nexus::Tenancy::Context.organization_id)}, #{conn.quote(name)},
              #{conn.quote(effect)}, #{conn.quote(matcher.to_json)}, #{priority}, now(), now())
      RETURNING id
    SQL
  end

  def decision_for(principal, action, resource_type, attributes: {})
    Nexus::Authorization::Authorize.call(principal, action, resource_type, attributes: attributes)
  end
end

RSpec.configure { |c| c.include AuthorizationHelpers }
