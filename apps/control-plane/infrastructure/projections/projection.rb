# frozen_string_literal: true

module Nexus
  module Projections
    # The read-model side of CQRS (ADR-004), applied per context rather than
    # globally — authorization, for instance, is deliberately *not* a CQRS
    # context, because a decision may never read stale state.
    #
    #     class RunSummary < Nexus::Projections::Projection
    #       projects "workflow.run.started", "workflow.run.finished"
    #
    #       def project(envelope) = …update the read model…
    #       def reset! = …truncate the read model for this tenant…
    #     end
    #
    # A PROJECTION IS A CONSUMER, AND THAT IS THE POINT
    #
    # It inherits checkpointing (the group's cursor) and deduplication (the
    # inbox) from the event backbone rather than growing its own. A separate
    # checkpoint table would be a second mechanism to keep correct, and the
    # first bug in it would look exactly like a projection that silently stopped
    # updating.
    #
    # The group name is derived from the class, so two projections never share
    # progress and adding one does not replay the others.
    #
    # DERIVED DATA IS NEVER AUTHORITATIVE
    #
    # Everything a projection writes must be reconstructible from the event log
    # by construction. That is what makes a projection failure a *delay* rather
    # than data loss, and it is why `reset!` is a required method rather than an
    # optional one: a projection that cannot be truncated cannot be rebuilt, and
    # a read model that cannot be rebuilt is authoritative by accident.
    class Projection < Nexus::Events::Consumer
      abstract!

      # Runs in the `projector` role, never in `consumer` — a rebuild must not
      # be able to consume the thread pool handling ordinary events (roles.yml).
      def self.role = :projector

      # Declare the event types this projection cares about. Anything else is
      # skipped — and the cursor still advances, because the projection has
      # genuinely finished with that event. Skipping is a decision, not a
      # deferral; holding the cursor would stall the whole partition on an event
      # this projection was never interested in.
      def self.projects(*event_types)
        @projected_types = event_types.map(&:to_s)
        consumes topic: Nexus::Events::Relay::DEFAULT_TOPIC, group: group_name_for(self)
      end

      def self.projected_types = @projected_types || []

      # Namespaced so a projection's cursor can never collide with an ordinary
      # consumer group, and so the name is stable across refactors of the class's
      # location — a changed group name is a silent full replay.
      def self.group_name_for(klass) = "projection:#{klass.name.demodulize.underscore}"

      # Projections are idempotent per event by construction, so the event id is
      # the right dedup key and subclasses do not have to think about it. This is
      # the one place a default is safe: unlike a side effect, applying the same
      # event twice to a read model is either identical or a bug in `project`.
      def dedup_key(envelope) = envelope.event_id

      def handle(envelope)
        return unless self.class.projected_types.empty? ||
                      self.class.projected_types.include?(envelope.event_type)

        project(envelope)
      end

      def project(_envelope)
        raise NotImplementedError, "#{self.class} must implement #project(envelope)"
      end

      # Remove everything this projection has written for the current tenant.
      # Required, not optional — see the class comment.
      def reset!
        raise NotImplementedError,
              "#{self.class} must implement #reset!. A projection that cannot be truncated cannot be " \
              "rebuilt, and a read model that cannot be rebuilt is authoritative by accident (ADR-004)."
      end
    end
  end
end
