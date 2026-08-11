# frozen_string_literal: true

module Nexus
  module Organizations
    # Public contract: create a new tenant.
    #
    # Provisioning looks like it needs a privileged back door — you cannot scope
    # to an organization you are in the act of creating. It does not.
    #
    # The trick is to generate the organization's UUID in the application, set
    # the tenant context to that UUID *before* inserting, and let the ordinary
    # tenant policy do the rest:
    #
    #     id = SecureRandom.uuid
    #     SET LOCAL nexus.organization_id = id     -- context is now the new tenant
    #     INSERT INTO organizations (id, ...) ...  -- WITH CHECK (id = setting) ✓
    #                               RETURNING id   -- USING      (id = setting) ✓
    #
    # So bootstrapping a tenant runs through exactly the same isolation layers as
    # every other write. There is no exemption policy, no session flag, and no
    # moment at which the tenant policy is not the only rule in force.
    #
    # This replaced an earlier design that used a `FOR INSERT` exemption policy;
    # it failed on `INSERT ... RETURNING` because RETURNING reads the row back
    # and reads are governed by USING, not WITH CHECK. See SEC-003 and
    # db/migrate/*_remove_provisioning_policy_exemption.rb.
    #
    # Everything happens in one transaction: a half-provisioned tenant — an
    # organization row with no roles — is unreachable through the product and
    # cannot be cleaned up through it either.
    class ProvisionOrganization
      Result = Struct.new(:organization_id, keyword_init: true)
      Error = Class.new(StandardError)

      def self.call(...) = new.call(...)

      # @param name [String]
      # @param slug [String] URL-safe, globally unique tenant identifier
      # @param region_code [String] must exist in `regions` (NFR-601 residency)
      # @param tier [String] "pool" | "dedicated" (ADR-009)
      def call(name:, slug:, region_code:, tier: "pool", database_key: nil)
        organization_id = SecureRandom.uuid

        ActiveRecord::Base.transaction do
          # The new tenant's context, established before its first row exists.
          Tenancy::Context.with(organization_id: organization_id) do
            Database::RowLevelSecurity.apply!

            organization = Internal::Models::Organization.new(
              id: organization_id,
              name: name, slug: slug, region_code: region_code,
              tier: tier, database_key: database_key
            )

            unless organization.save
              raise Error, "could not provision organization: #{organization.errors.full_messages.join(', ')}"
            end

            # Authorization owns roles; go through its published contract (INV-01).
            Nexus::Authorization::SeedSystemRoles.call
          end
        end

        Result.new(organization_id: organization_id)
      end

    end
  end
end
