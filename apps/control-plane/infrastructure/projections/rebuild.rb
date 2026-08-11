# frozen_string_literal: true

module Nexus
  module Projections
    # Rebuild a read model from history.
    #
    # This is the operation that makes "derived data failure is never data loss"
    # true rather than aspirational. If it does not work, every projection is
    # quietly authoritative and the event log is decoration.
    #
    # THREE STEPS, AND SKIPPING ANY ONE OF THEM FAILS SILENTLY
    #
    #   1. Truncate the read model. Skipping this double-counts, because the
    #      projection is about to re-apply events it already applied.
    #   2. Purge the projection's inbox claims. Skipping this deduplicates the
    #      entire replay away — the rebuild reports success and changes nothing,
    #      which is the worst outcome for an operation reached for during an
    #      incident.
    #   3. Rewind the cursor. Skipping this replays nothing at all.
    #
    # Steps 2 and 3 are `Events::Replay.reprocess!`, which requires the caller to
    # acknowledge that handlers will re-run. A projection is precisely the case
    # where that is safe — it has no side effects outside its own tables — so
    # this is the one caller that passes the flag without needing to think hard.
    module Rebuild
      Result = Struct.new(:projection, :cleared, :replayed, keyword_init: true)

      module_function

      # @param projection [Class<Projection>]
      # @return [Result]
      def call(projection:, organization_id:, limit: 1_000)
        assert_projection!(projection)

        cleared = clear_read_model(projection, organization_id)

        Nexus::Events::Replay.reprocess!(
          group: projection.group_name,
          organization_id: organization_id,
          topic: projection.topic_name,
          from_position: 0,
          i_understand_handlers_will_rerun: true
        )

        replayed = drain(projection, organization_id, limit)

        Result.new(projection: projection.name, cleared: cleared, replayed: replayed)
      end

      def all(organization_id:, limit: 1_000)
        Runner.registry.map { |p| call(projection: p, organization_id: organization_id, limit: limit) }
      end

      def assert_projection!(projection)
        return if projection.respond_to?(:group_name) && projection <= Projection

        raise ArgumentError, "#{projection} is not a Nexus::Projections::Projection"
      end

      def clear_read_model(projection, organization_id)
        Nexus::Tenancy::Context.with(organization_id: organization_id) do
          ActiveRecord::Base.transaction(requires_new: true) do
            Nexus::Database::RowLevelSecurity.apply!
            projection.new.reset!
          end
        end
        true
      end

      # Replay to completion rather than leaving it to the projector loop: a
      # rebuild that returns before the read model is current invites someone to
      # look at it and conclude the rebuild was wrong.
      def drain(projection, organization_id, limit)
        total = 0

        loop do
          processed = projection.consume(organization_id: organization_id, limit: limit).processed
          total += processed
          break if processed.zero?
        end

        total
      end
    end
  end
end
