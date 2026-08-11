# frozen_string_literal: true

module Nexus
  module Workflows
    module Internal
      module Models
        # Immutable once published. Runs point HERE, never at the definition,
        # so editing a workflow cannot reach a run already in flight (INV-12).
        class WorkflowVersion < TenantScopedRecord
          self.table_name = "workflow_versions"

          belongs_to :workflow_definition,
                     class_name: "Nexus::Workflows::Internal::Models::WorkflowDefinition"

          validates :version, numericality: { only_integer: true, greater_than: 0 }
          validates :checksum, presence: true

          def published? = published_at.present?

          # Detects a version row mutated in place — the one thing INV-12
          # forbids and the database cannot prevent on its own.
          def intact? = checksum == self.class.checksum_for(definition)

          def self.checksum_for(definition) = Digest::SHA256.hexdigest(Oj.dump(definition, mode: :strict))
        end
      end
    end
  end
end
