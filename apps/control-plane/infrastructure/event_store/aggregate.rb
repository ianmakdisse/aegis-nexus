# frozen_string_literal: true

module Nexus
  module EventStore
    # The base class for the four event-sourced aggregates (ADR-005).
    #
    #     class WorkflowRun < Nexus::EventStore::Aggregate
    #       stream_type "WorkflowRun"
    #
    #       on "workflow.run.started" do |state, payload|
    #         state.merge("status" => "running", "definition" => payload["definition_key"])
    #       end
    #
    #       def start!(definition_key:)
    #         emit "workflow.run.started", definition_key: definition_key
    #       end
    #     end
    #
    # APPLIERS ARE PURE FUNCTIONS. THIS IS THE WHOLE DISCIPLINE.
    #
    # An applier takes the current state and an event's payload and returns the
    # next state. It must not read the database, call a service, generate a
    # random value, or look at the clock.
    #
    # The reason is replay. Rebuilding an aggregate re-runs every applier over
    # its entire history, possibly years later, possibly thousands of times
    # during a projection rebuild. An applier that does I/O turns a replay into
    # a load test; one that reads the clock or a random value produces a
    # *different* aggregate each time it is rebuilt, which means the history no
    # longer determines the state — and at that point the event log is
    # decoration rather than the source of truth.
    #
    # Anything non-deterministic belongs in the command (`emit`), where it is
    # computed once and recorded in the payload forever.
    class Aggregate
      NotLoaded = Class.new(StandardError)

      class << self
        def stream_type(name = nil)
          @stream_type = name if name
          @stream_type || self.name.demodulize
        end

        def appliers = @appliers ||= {}

        def on(event_type, &applier)
          appliers[event_type.to_s] = applier
        end

        # Rebuild from history: the newest snapshot, then every event after it.
        def load(id)
          loaded = Nexus::Events::EventStore.load(stream_id: id, stream_type: stream_type)
          new(id: id, state: loaded.snapshot || {}, sequence: loaded.sequence).tap do |aggregate|
            loaded.events.each { |envelope| aggregate.send(:replay, envelope) }
          end
        end

        def new_stream(id = SecureRandom.uuid) = new(id: id, state: {}, sequence: 0)
      end

      attr_reader :id, :state, :sequence

      def initialize(id:, state:, sequence:)
        @id = id
        @state = state
        @sequence = sequence
        @pending = []
      end

      def new_record? = sequence.zero? && @pending.any?
      def pending_count = @pending.size

      # Stage an event and apply it locally, so the aggregate is immediately
      # consistent with what it is about to persist. Nothing is written until
      # `save!`.
      def emit(event_type, payload = {})
        envelope = Nexus::Events::Envelope.new(
          event_type: event_type.to_s,
          payload: payload,
          partition_key: id.to_s,
          organization_id: Nexus::Tenancy::Context.organization_id
        )

        @pending << envelope
        @state = apply(state, envelope)
        self
      end

      # Append staged events at the sequence this aggregate was loaded at. If
      # another writer advanced the stream in the meantime, the store raises
      # ConcurrencyConflict — reload and retry, because the other writer's
      # events are already history and cannot be argued with.
      def save!
        return self if @pending.empty?

        expected = sequence
        @sequence = Nexus::Events::EventStore.append(
          stream_id: id, stream_type: self.class.stream_type,
          events: @pending, expected_sequence: expected
        )
        @pending = []

        maybe_snapshot!
        self
      end

      private

      def apply(current, envelope)
        applier = self.class.appliers[envelope.event_type]
        # An unknown event type is not an error: an older version of this code
        # legitimately does not understand an event a newer version emitted, and
        # a replay must not crash on it. Ignoring it keeps the fold total.
        return current if applier.nil?

        applier.call(current, envelope.payload).freeze
      end

      def replay(envelope)
        @state = apply(@state, envelope)
        @sequence = [@sequence, 0].max
      end

      # Best effort by design: a failed snapshot costs replay time, never
      # correctness, so it must never fail the write that triggered it.
      def maybe_snapshot!
        return unless Nexus::Events::EventStore.snapshot_due?(sequence)

        Nexus::Events::EventStore.snapshot!(
          stream_id: id, stream_type: self.class.stream_type,
          sequence: sequence, state: state
        )
      rescue StandardError => e
        Rails.logger.warn("[event-store] snapshot failed for #{id}@#{sequence}: #{e.class}")
      end
    end
  end
end
