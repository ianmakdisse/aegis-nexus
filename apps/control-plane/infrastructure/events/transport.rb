# frozen_string_literal: true

module Nexus
  module Events
    # The transport port (ADR-003).
    #
    # The contract is exactly the semantics we rely on and nothing more. It
    # deliberately does NOT expose transactions, compacted topics, or partition
    # assignment control — if we ever need those, we change the ADR rather than
    # leak Kafka into domain code.
    #
    # The port exists for testability and deployment flexibility, not for vendor
    # neutrality theater. Being able to run the entire event path — publication,
    # consumer groups, replay, duplicate delivery, crash recovery — against a
    # single PostgreSQL instance is what makes those correctness tests runnable
    # in CI at all. That is the whole argument, and it is why `PostgresLogTransport`
    # is a first-class implementation rather than a mock.
    module Transport
      Unavailable = Class.new(StandardError)

      # Ordering is guaranteed only among events sharing a partition key
      # (INV-09). Sixteen partitions is a development-scale default; the number
      # is a property of the transport, and changing it re-shuffles which keys
      # share a partition — so it is a migration, not a config tweak.
      PARTITIONS = 16

      module_function

      def current
        @current ||= build(Rails.application.config.x.events.transport)
      end

      def build(name)
        case name.to_s
        when "postgres" then PostgresLogTransport.new
        when "kafka"
          # Deliberately not stubbed. A transport that silently does nothing is
          # worse than one that refuses to start: the first loses events while
          # reporting success.
          raise Unavailable, "KafkaTransport is not implemented (Phase 14). Set NEXUS_EVENT_TRANSPORT=postgres."
        else
          raise Unavailable, "unknown transport #{name.inspect}"
        end
      end

      # Test seam. Resetting is explicit rather than automatic so a spec cannot
      # accidentally leave a different transport installed for the next one.
      def reset! = @current = nil

      def partition_for(key) = Zlib.crc32(key.to_s) % PARTITIONS

      # The contract every implementation satisfies. Documented as a class so the
      # required methods are readable in one place, and so an incomplete
      # implementation fails loudly at the call rather than by returning nil.
      class Port
        def publish(topic:, key:, payload:, headers:) = not_implemented(:publish)
        def read(group:, topic:, limit:) = not_implemented(:read)
        def commit(group:, topic:, partition_number:, position:) = not_implemented(:commit)
        def seek(group:, topic:, partition_number:, position:) = not_implemented(:seek)

        private

        def not_implemented(method)
          raise NotImplementedError, "#{self.class} must implement ##{method}"
        end
      end
    end
  end
end
