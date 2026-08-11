# frozen_string_literal: true

module Nexus
  module Workflows
    module Internal
      module Models
        # Tenant-authored: data with platform-enforced governance, not deployed
        # code. That distinction is the whole argument of ADR-006.
        class WorkflowDefinition < TenantScopedRecord
          self.table_name = "workflow_definitions"

          STATUSES = %w[draft active archived].freeze

          has_many :versions, class_name: "Nexus::Workflows::Internal::Models::WorkflowVersion",
                              foreign_key: :workflow_definition_id, dependent: :destroy

          validates :key, :name, presence: true
          validates :key, uniqueness: { scope: :organization_id }
          validates :status, inclusion: { in: STATUSES }

          def latest_version = versions.order(version: :desc).first
          def published_version = versions.where.not(published_at: nil).order(version: :desc).first
        end
      end
    end
  end
end
