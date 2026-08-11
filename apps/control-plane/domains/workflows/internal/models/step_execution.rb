# frozen_string_literal: true

module Nexus
  module Workflows
    module Internal
      module Models
        # One row per ATTEMPT. A retry never overwrites the failure it is
        # retrying: the previous row is the evidence of what went wrong, and
        # overwriting it is how a flaky step becomes an unexplainable one.
        class StepExecution < TenantScopedRecord
          self.table_name = "step_executions"

          STATUSES = %w[running succeeded failed skipped].freeze

          validates :step_key, :step_type, :idempotency_key, presence: true
          validates :status, inclusion: { in: STATUSES }

          # Derived from durable identifiers only. A key that changes on retry
          # defeats the deduplication it exists for (INV-05).
          def self.idempotency_key_for(run_id:, step_key:, attempt:)
            "run:#{run_id}:step:#{step_key}:attempt:#{attempt}"
          end
        end
      end
    end
  end
end
