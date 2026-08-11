# frozen_string_literal: true

module Nexus
  module Workflows
    module Internal
      module Models
        # A lease, not a lock. A lock held by a process that was killed
        # mid-step is held forever; a lease expires on the DATABASE's clock and
        # the run is reclaimed.
        class RunLease < TenantScopedRecord
          self.table_name = "run_leases"

          validates :worker_id, presence: true

          # Expiry is evaluated by the database, never by the worker. A process
          # with a skewed clock must not be able to believe it still holds a
          # lease the database considers dead.
          scope :live, -> { where("expires_at > now()") }
          scope :expired, -> { where("expires_at <= now()") }
        end
      end
    end
  end
end
