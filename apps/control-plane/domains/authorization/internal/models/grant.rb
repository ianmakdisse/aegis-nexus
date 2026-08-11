# frozen_string_literal: true

module Nexus
  module Authorization
    module Internal
      module Models
        # Binds a role to exactly one subject: a membership (a human, in this
        # tenant) or a service identity (a machine). The database enforces the
        # exclusivity with a CHECK constraint; this model refuses to build the
        # invalid shape earlier, where the error is readable.
        #
        # `membership_id` and `service_identity_id` are plain UUID columns rather
        # than associations. Memberships belong to Organizations and service
        # identities to Identity, and INV-01 forbids this context from reading
        # either table — a `belongs_to` would generate exactly that query. An
        # opaque identifier is the whole point of a boundary.
        class Grant < TenantScopedRecord
          self.table_name = "grants"

          belongs_to :role, class_name: "Nexus::Authorization::Internal::Models::Role"

          validate :exactly_one_subject

          # Expiry is evaluated with the DATABASE's clock, never the application's.
          # A worker with a skewed clock must not be able to honor a grant the
          # database considers expired (see the failure matrix: "time is not a
          # coordination primitive").
          scope :active, -> { where("expires_at IS NULL OR expires_at > now()") }

          scope :for_membership, ->(id) { where(membership_id: id) }
          scope :for_service_identity, ->(id) { where(service_identity_id: id) }

          private

          def exactly_one_subject
            subjects = [membership_id, service_identity_id].compact
            return if subjects.size == 1

            errors.add(:base, "a grant binds a role to exactly one subject — " \
                              "either a membership or a service identity, never both and never neither")
          end
        end
      end
    end
  end
end
