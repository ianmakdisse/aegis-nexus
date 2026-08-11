# frozen_string_literal: true

module Nexus
  module Events
    module Internal
      module Models
        # One immutable fact in an aggregate's history. Never updated, never
        # deleted — a correction is a new event, because editing history is
        # the failure mode event sourcing exists to prevent.
        class EventStoreEvent < TenantScopedRecord
          self.table_name = "event_store_events"

          validates :stream_id, :stream_type, :event_type, presence: true
          validates :sequence, numericality: { only_integer: true, greater_than: 0 }
        end
      end
    end
  end
end
