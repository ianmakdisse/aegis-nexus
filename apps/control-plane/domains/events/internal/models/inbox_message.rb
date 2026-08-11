# frozen_string_literal: true

module Nexus
  module Events
    module Internal
      module Models
        # Consumer-side deduplication (INV-05). The unique index on
        # (organization_id, consumer_group, dedup_key) is the enforcement — not
        # a `find_by` the handler might race against.
        class InboxMessage < TenantScopedRecord
          self.table_name = "inbox_messages"

          validates :consumer_group, :dedup_key, presence: true

          # Claim the right to process, exactly once. Returns false if another
          # delivery already claimed it.
          #
          # Two concurrent consumers both pass a `SELECT` check and both proceed;
          # only one survives the unique index. Catching the violation rather
          # than checking first is what makes this correct under concurrency.
          def self.claim(consumer_group:, dedup_key:, event_type: nil)
            create!(consumer_group: consumer_group, dedup_key: dedup_key,
                    event_type: event_type, processed_at: Time.current)
            true
          rescue ActiveRecord::RecordNotUnique
            false
          end
        end
      end
    end
  end
end
