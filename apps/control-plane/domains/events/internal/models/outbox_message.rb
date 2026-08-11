# frozen_string_literal: true

module Nexus
  module Events
    module Internal
      module Models
        # The transactional outbox (INV-04). Written with the state it describes;
        # drained by the relay.
        class OutboxMessage < TenantScopedRecord
          self.table_name = "outbox_messages"

          validates :event_type, :partition_key, presence: true

          # The relay's working set. Ordered by creation so that events sharing a
          # partition key are published in the order they were committed —
          # ordering is per-key, and this is where that promise is kept.
          scope :unpublished, -> { where(published_at: nil).order(:created_at) }

          def published? = published_at.present?
        end
      end
    end
  end
end
