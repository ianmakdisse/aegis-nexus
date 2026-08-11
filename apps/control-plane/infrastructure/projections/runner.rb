# frozen_string_literal: true

module Nexus
  module Projections
    # The `projector` role (bin/role-entrypoint).
    #
    # Isolated from the `consumer` role so a rebuild never touches the write
    # path, and from `api` so a projection catching up on six months of history
    # cannot consume the threads serving p95-sensitive traffic.
    module Runner
      DEFAULT_INTERVAL = 1.0

      Lag = Struct.new(:projection, :behind, :position, :head, keyword_init: true) do
        # Zero means caught up. Anything else is *staleness*, which is a
        # different problem from divergence — see `Runner.lag`.
        def caught_up? = behind.zero?
      end

      module_function

      def registry = Nexus::Events::Consumer.registry_for(:projector)

      # One pass over every tenant, for every projection.
      def tick(tenant_source: nil, limit: 100)
        Nexus::Events::Relay.each_tenant_id(tenant_source).sum do |organization_id|
          registry.sum { |p| p.consume(organization_id: organization_id, limit: limit).processed }
        end
      end

      def run!(tenant_source: nil, interval: DEFAULT_INTERVAL, limit: 100)
        loop do
          processed = tick(tenant_source: tenant_source, limit: limit)
          sleep(interval) if processed.zero?
        end
      end

      # How far behind each projection is, for one tenant.
      #
      # THIS MEASURES LAG, NOT DIVERGENCE, AND THEY ARE DIFFERENT INCIDENTS.
      #
      # Lag means the read model is *stale* — correct, just behind. The action
      # is to wait, or to scale the projector role.
      #
      # Divergence means the read model is *wrong* — it processed everything and
      # still disagrees with the log, which is a bug in `project`. The action is
      # to rebuild. Detecting divergence needs reconciliation against the event
      # store and is Phase 12; conflating the two is why "the dashboard is
      # wrong" gets answered with "wait a minute" for an hour.
      def lag(organization_id:)
        Nexus::Tenancy::Context.with(organization_id: organization_id) do
          ActiveRecord::Base.transaction(requires_new: true) do
            Nexus::Database::RowLevelSecurity.apply!
            heads = partition_heads

            registry.map { |projection| lag_for(projection, heads) }
          end
        end
      end

      def lag_for(projection, heads)
        group = projection.group_name
        position = 0
        head = 0

        heads.each do |partition, partition_head|
          head += partition_head
          position += Nexus::Events::Internal::Models::EventLogCursor.position_for(
            consumer_group: group, topic: projection.topic_name, partition_number: partition
          )
        end

        Lag.new(projection: projection.name, behind: head - position, position: position, head: head)
      end

      def partition_heads
        Nexus::Events::Internal::Models::EventLogEntry
          .group(:partition_number).maximum(:position)
      end
    end
  end
end
