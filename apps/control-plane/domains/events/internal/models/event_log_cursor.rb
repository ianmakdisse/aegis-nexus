# frozen_string_literal: true

module Nexus
  module Events
    module Internal
      module Models
        # How far a consumer group has PROCESSED a tenant's partition.
        #
        # Committed after the handler succeeds, never before. On a crash the
        # entry is re-read and the inbox deduplicates it; committing first would
        # turn the same crash into silent data loss, which is the asymmetry that
        # makes at-least-once the right default.
        class EventLogCursor < TenantScopedRecord
          self.table_name = "event_log_cursors"

          validates :consumer_group, :topic, presence: true

          def self.position_for(consumer_group:, topic:, partition_number:)
            find_by(consumer_group: consumer_group, topic: topic,
                    partition_number: partition_number)&.position.to_i
          end

          def self.commit!(consumer_group:, topic:, partition_number:, position:)
            cursor = find_or_initialize_by(consumer_group: consumer_group, topic: topic,
                                           partition_number: partition_number)
            # Never move a cursor backwards: a late or duplicated commit from a
            # slow worker must not un-process everything after it.
            return cursor if cursor.persisted? && cursor.position >= position

            cursor.position = position
            cursor.committed_at = Time.current
            cursor.save!
            cursor
          end
        end
      end
    end
  end
end
