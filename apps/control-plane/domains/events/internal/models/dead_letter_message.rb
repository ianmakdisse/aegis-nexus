# frozen_string_literal: true

module Nexus
  module Events
    module Internal
      module Models
        # Where a message goes when a handler has failed its retry budget.
        #
        # The full payload and headers are kept because the only useful thing to
        # do with a dead letter is fix the handler and replay it — and a dead
        # letter you cannot replay is just an error log with extra steps.
        class DeadLetterMessage < TenantScopedRecord
          self.table_name = "dead_letter_messages"

          validates :consumer_group, :event_type, presence: true

          scope :unreplayed, -> { where(replayed_at: nil) }
        end
      end
    end
  end
end
