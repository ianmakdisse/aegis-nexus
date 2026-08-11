# frozen_string_literal: true

module Nexus
  module Workflows
    module Internal
      module Models
        # The row is the read side; the authoritative history is the event
        # stream (ADR-005). A waiting run costs exactly this one indexed row
        # and zero workers — which is what makes a week-long sleep affordable.
        class WorkflowRun < TenantScopedRecord
          self.table_name = "workflow_runs"

          STATUSES = %w[pending running sleeping waiting_approval succeeded failed cancelled].freeze
          TERMINAL = %w[succeeded failed cancelled].freeze

          belongs_to :workflow_version,
                     class_name: "Nexus::Workflows::Internal::Models::WorkflowVersion"

          validates :status, inclusion: { in: STATUSES }

          scope :runnable, -> { where(status: %w[pending running]) }

          def terminal? = TERMINAL.include?(status)
        end
      end
    end
  end
end
