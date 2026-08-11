# frozen_string_literal: true

module Nexus
  module Events
    module Internal
      module Models
        # One entry in the PostgreSQL transport's durable log.
        class EventLogEntry < TenantScopedRecord
          self.table_name = "event_log_entries"

          validates :topic, :partition_key, :event_type, presence: true

          scope :in_partition, ->(topic, partition) { where(topic: topic, partition_number: partition) }
          scope :after, ->(position) { where("position > ?", position).order(:position) }

          # The next position in this tenant's partition.
          #
          # Read inside the relay's transaction, so the row lock taken by the
          # subsequent INSERT serializes concurrent relays through the unique
          # index rather than through an application-level lock. A loser sees
          # RecordNotUnique and retries — which is correct, because the log must
          # be dense and gapless for a cursor to mean anything.
          def self.next_position(topic:, partition_number:)
            in_partition(topic, partition_number).maximum(:position).to_i + 1
          end
        end
      end
    end
  end
end
