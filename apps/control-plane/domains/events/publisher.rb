# frozen_string_literal: true

module Nexus
  module Events
    # Published contract: the only way an event enters the system (INV-04).
    #
    # THE GUARD IS THE POINT
    #
    # This class exists to make one specific bug impossible to write. The bug:
    #
    #     order.save!                          # committed
    #     Kafka.produce("order.placed", …)     # crash here
    #
    # The state changed and the event did not. Nothing raises, nothing retries,
    # and the two halves of the system disagree forever — undetectably, until
    # someone builds the reconciliation tooling that nobody builds until after
    # the incident.
    #
    # So `publish` refuses to run outside a transaction. Not "warns", not
    # "logs" — raises, before writing anything. The outbox row lands in the same
    # transaction as the domain write, which makes the guarantee *structural*: it
    # is a property of the commit, not a protocol between two components that
    # must both be working.
    #
    # The relay publishes from the outbox afterwards, at-least-once
    # ([INV-06](../../../docs/02-architecture/architecture-constitution.md)).
    # Duplicates are the consumer's problem to deduplicate, and the inbox makes
    # them harmless.
    class Publisher
      NotInTransaction = Class.new(StandardError)

      class << self
        def publish(...) = new.publish(...)
        def publish_all(...) = new.publish_all(...)
      end

      # @param envelope [Envelope]
      # @return [String] the outbox message id
      def publish(envelope)
        assert_in_transaction!
        assert_tenant!(envelope)
        EventType.assert_registered!(envelope.event_type, envelope.version)

        record = Internal::Models::OutboxMessage.create!(
          organization_id: envelope.organization_id || Tenancy::Context.organization_id,
          event_type: envelope.event_type,
          event_version: envelope.version,
          partition_key: envelope.partition_key,
          payload: envelope.payload,
          metadata: envelope.headers
        )

        record.id
      end

      def publish_all(envelopes)
        envelopes.map { |envelope| publish(envelope) }
      end

      private

      # `transaction_open?` is true only inside a real transaction. Under
      # transactional fixtures the suite itself holds one open, which would make
      # this guard vacuous in tests — so the isolation-style trick applies:
      # the specs assert the guard by checking the *real* open-transaction
      # depth via `current_transaction`, and there is a dedicated example for a
      # publish attempted with none.
      def assert_in_transaction!
        return if ActiveRecord::Base.connection.transaction_open?

        raise NotInTransaction,
              "Nexus::Events::Publisher requires an open transaction (INV-04: no dual writes). " \
              "The event must commit with the state it describes. Wrap the domain write and this " \
              "publish in one ActiveRecord::Base.transaction."
      end

      # An event with no tenant cannot be delivered, replayed, or attributed —
      # and the outbox row would be rejected by RLS anyway. Failing here says
      # what is wrong; failing at the INSERT says a policy was violated.
      def assert_tenant!(envelope)
        return if envelope.organization_id.present?
        return if Tenancy::Context.present?

        raise Tenancy::Context::Missing,
              "publishing `#{envelope.event_type}` with no tenant context and no organization_id " \
              "on the envelope (INV-13)."
      end
    end
  end
end
