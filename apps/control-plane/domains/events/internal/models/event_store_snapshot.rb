# frozen_string_literal: true

module Nexus
  module Events
    module Internal
      module Models
        # A cached fold, never authoritative (ADR-005). Deleting every row here
        # costs replay time and cannot change an answer — which is the property
        # that lets snapshots be written on a best-effort basis.
        class EventStoreSnapshot < TenantScopedRecord
          self.table_name = "event_store_snapshots"

          validates :stream_id, :stream_type, presence: true
          validates :sequence, numericality: { only_integer: true, greater_than: 0 }
        end
      end
    end
  end
end
