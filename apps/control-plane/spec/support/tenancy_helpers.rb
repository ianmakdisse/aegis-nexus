# frozen_string_literal: true

module TenancyHelpers
  # Provisioning goes through the real public contract, not a test-only
  # shortcut. A helper that bypasses the production path ends up testing the
  # helper — and would have hidden the transaction bug in SEC-003.
  def provision_organization!(name:, slug:, region_code: "sa-east-1")
    seed_region!(code: region_code)
    Nexus::Organizations::ProvisionOrganization
      .call(name: name, slug: slug, region_code: region_code)
      .organization_id
  end

  def seed_region!(code: "sa-east-1")
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL.squish)
      INSERT INTO regions (code, name, residency_zone, created_at, updated_at)
      VALUES (#{conn.quote(code)}, 'Test Region', 'BR', now(), now())
      ON CONFLICT (code) DO NOTHING
    SQL
  end

  def create_user!(email:)
    conn = ActiveRecord::Base.connection
    conn.select_value(<<~SQL.squish)
      INSERT INTO users (email, created_at, updated_at)
      VALUES (#{conn.quote(email)}, now(), now())
      RETURNING id
    SQL
  end

  # Run inside a tenant context with the RLS session variable applied — i.e. all
  # three isolation layers active, exactly as production runs.
  #
  # Wrapped in a transaction because SET LOCAL is transaction-scoped; under
  # transactional fixtures this becomes a savepoint, which is fine.
  def as_tenant(organization_id, &block)
    Nexus::Tenancy::Context.with(organization_id: organization_id) do
      ActiveRecord::Base.transaction(requires_new: true) do
        Nexus::Database::RowLevelSecurity.apply!
        block.call
      end
    end
  end

  # Disable layers (b) and (c) to prove layer (a) — the database — still denies.
  def with_application_layers_disabled
    original = Rails.application.config.x.tenancy.enforce_context
    Rails.application.config.x.tenancy.enforce_context = false
    yield
  ensure
    Rails.application.config.x.tenancy.enforce_context = original
  end
end

RSpec.configure { |c| c.include TenancyHelpers }
