# frozen_string_literal: true

module Nexus
  module Events
    # Published contract: the authoritative history of the four event-sourced
    # aggregates (ADR-005).
    #
    # WHAT THIS IS NOT
    #
    # Not the event log. The log carries facts outward and is drained; this is
    # the *record*, and it is never drained. A projection rebuild reads from
    # here, not from Kafka — which is why ADR-003 says the event store is the
    # replay source and the broker is not.
    #
    # OPTIMISTIC CONCURRENCY
    #
    # Appending declares the sequence the caller last saw. If another writer got
    # there first, the unique index on `(organization_id, stream_id, sequence)`
    # rejects the insert and this raises `ConcurrencyConflict`. The check is the
    # database's, not the application's: a `SELECT max(sequence)` followed by an
    # `INSERT` is a race that two concurrent workers both win.
    #
    # This is also why the event store cannot be time-partitioned — a unique
    # constraint on a partitioned table must include the partition key, which
    # would permit two events at the same sequence (ADR-012).
    #
    # STORE AND PUBLISH COMMIT TOGETHER
    #
    # Appending writes the event rows *and* their outbox rows in one
    # transaction (INV-04). An aggregate whose history advanced but whose events
    # never reached the backbone is the dual-write bug wearing a different hat.
    class EventStore
      ConcurrencyConflict = Class.new(StandardError)
      UnknownStream = Class.new(StandardError)

      # ADR-005: a snapshot is a cache, taken every N events. Losing every
      # snapshot costs replay time and nothing else.
      SNAPSHOT_INTERVAL = 100

      Loaded = Struct.new(:stream_id, :stream_type, :sequence, :events, :snapshot, keyword_init: true) do
        def empty? = sequence.zero?
      end

      class << self
        # @param expected_sequence [Integer] the sequence the caller last saw.
        #   0 for a new stream. A mismatch means someone else wrote first.
        # @param events [Array<Envelope>]
        # @return [Integer] the stream's new sequence
        def append(stream_id:, stream_type:, events:, expected_sequence:)
          return expected_sequence if events.empty?

          organization_id = Tenancy::Context.organization_id
          sequence = expected_sequence

          ActiveRecord::Base.transaction(requires_new: true) do
            events.each do |envelope|
              sequence += 1
              write_event!(organization_id, stream_id, stream_type, sequence, envelope)

              # Same transaction as the event it describes. This is the whole
              # reason ADR-002 chose one datastore.
              Publisher.publish(stream_envelope(envelope, stream_id, organization_id))
            end
          end

          sequence
        rescue ActiveRecord::RecordNotUnique
          raise ConcurrencyConflict,
                "stream #{stream_type}/#{stream_id} advanced past sequence #{expected_sequence} " \
                "while this write was in flight. Reload the aggregate and retry — the other writer's " \
                "events are already history."
        end

        # Everything needed to rebuild an aggregate: the newest snapshot, and
        # every event after it.
        def load(stream_id:, stream_type:)
          snapshot = newest_snapshot(stream_id, stream_type)
          from = snapshot&.sequence.to_i

          events = Internal::Models::EventStoreEvent
                   .where(stream_id: stream_id, stream_type: stream_type)
                   .where("sequence > ?", from)
                   .order(:sequence)
                   .to_a

          Loaded.new(
            stream_id: stream_id, stream_type: stream_type,
            sequence: events.last&.sequence || from,
            events: events.map { |row| to_envelope(row) },
            snapshot: snapshot&.state
          )
        end

        # A snapshot is never authoritative. It is written on a best-effort
        # basis and a corrupt or missing one costs a full replay, never a wrong
        # answer — which is why this swallows a duplicate rather than failing the
        # caller's operation.
        def snapshot!(stream_id:, stream_type:, sequence:, state:)
          Internal::Models::EventStoreSnapshot.create!(
            stream_id: stream_id, stream_type: stream_type,
            sequence: sequence, state: state
          )
          true
        rescue ActiveRecord::RecordNotUnique
          false
        end

        def snapshot_due?(sequence) = sequence.positive? && (sequence % SNAPSHOT_INTERVAL).zero?

        def current_sequence(stream_id:, stream_type:)
          Internal::Models::EventStoreEvent
            .where(stream_id: stream_id, stream_type: stream_type)
            .maximum(:sequence).to_i
        end

        private

        def write_event!(organization_id, stream_id, stream_type, sequence, envelope)
          Internal::Models::EventStoreEvent.create!(
            organization_id: organization_id,
            stream_id: stream_id,
            stream_type: stream_type,
            sequence: sequence,
            event_type: envelope.event_type,
            event_version: envelope.version,
            payload: envelope.payload,
            metadata: envelope.headers,
            occurred_at: envelope.occurred_at
          )
        end

        # The stream id is the partition key: every event for one aggregate
        # lands in one partition and is therefore delivered in order (INV-09).
        # Choosing anything else here would silently break per-aggregate
        # ordering downstream.
        def stream_envelope(envelope, stream_id, organization_id)
          Envelope.new(
            event_type: envelope.event_type, version: envelope.version,
            payload: envelope.payload, partition_key: stream_id.to_s,
            organization_id: organization_id, event_id: envelope.event_id,
            occurred_at: envelope.occurred_at, trace_id: envelope.trace_id,
            correlation_id: envelope.correlation_id, causation_id: envelope.causation_id,
            actor: envelope.actor
          )
        end

        def newest_snapshot(stream_id, stream_type)
          Internal::Models::EventStoreSnapshot
            .where(stream_id: stream_id, stream_type: stream_type)
            .order(sequence: :desc).first
        end

        def to_envelope(row)
          Envelope.new(
            event_type: row.event_type, version: row.event_version,
            payload: row.payload, partition_key: row.stream_id.to_s,
            organization_id: row.organization_id, event_id: row.metadata["event_id"],
            occurred_at: row.occurred_at, trace_id: row.metadata["trace_id"],
            correlation_id: row.metadata["correlation_id"],
            causation_id: row.metadata["causation_id"], actor: row.metadata["actor"]
          )
        end
      end
    end
  end
end
