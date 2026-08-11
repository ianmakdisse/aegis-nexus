# frozen_string_literal: true

module Nexus
  module Events
    module Internal
      module Models
        # The event vocabulary. Platform-global (ADR-012) for the same reason
        # `permissions` is: it describes the software, not a tenant.
        #
        # Named EventTypeRecord because `Events::EventType` is the published
        # contract — the same separation Authorization keeps between `Policy` and
        # `Internal::Models::PolicyRecord`, and for the same reason: an
        # ActiveRecord object must not be what crosses a boundary.
        class EventTypeRecord < ApplicationRecord
          self.table_name = "event_type_registry"

          STATUSES = %w[active deprecated].freeze

          validates :key, :owning_context, presence: true
          validates :version, numericality: { only_integer: true, greater_than: 0 }
          validates :status, inclusion: { in: STATUSES }
        end
      end
    end
  end
end
