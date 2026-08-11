# frozen_string_literal: true

module Nexus
  module Workflows
    module Internal
      module Models
        # The due-time queue (ADR-003). Not the event log: delays, retries and
        # week-long waits are a different problem from fan-out and replay, and
        # solving them with retry topics destroys the ordering guarantee.
        class ScheduledJob < TenantScopedRecord
          self.table_name = "scheduled_jobs"

          STATUSES = %w[pending claimed done failed].freeze

          validates :kind, presence: true
          validates :status, inclusion: { in: STATUSES }

          scope :due, -> { where(status: "pending").where("run_at <= now()").order(:run_at) }
        end
      end
    end
  end
end
