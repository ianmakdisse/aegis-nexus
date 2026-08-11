# frozen_string_literal: true

module Nexus
  module Authorization
    module Internal
      module Models
        # The persisted form of an ABAC policy.
        #
        # Named PolicyRecord rather than Policy on purpose: `Authorization::Policy`
        # is the published contract — an immutable value object other contexts may
        # hold — and two constants a namespace apart differing only in what they
        # are is how a reader ends up passing an ActiveRecord object across a
        # boundary without noticing.
        class PolicyRecord < TenantScopedRecord
          self.table_name = "policies"

          EFFECTS = %w[allow deny].freeze

          validates :name, presence: true
          validates :effect, inclusion: { in: EFFECTS }
          validates :priority, numericality: { only_integer: true }

          # Lower priority value wins. Ties are broken toward `deny` by the
          # evaluator, not here — ordering is a storage concern, precedence is a
          # security decision and belongs where it can be tested.
          scope :in_precedence_order, -> { order(:priority, :created_at) }
        end
      end
    end
  end
end
