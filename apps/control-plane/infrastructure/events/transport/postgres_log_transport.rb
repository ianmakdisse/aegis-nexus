# frozen_string_literal: true

module Nexus
  module Events
    module Transport
      # The durable log, in PostgreSQL (ADR-003).
      #
      # Every operation runs inside the caller's tenant context, so row-level
      # security governs the log exactly as it governs domain data. That is the
      # reason this transport reads and writes per tenant rather than globally:
      # no application role bypasses RLS (INV-14), so there is no such thing as
      # a global scan here.
      #
      # What this gives up versus Kafka: throughput, and cross-tenant consumer
      # parallelism. What it buys: the entire event path runs in CI against one
      # database, including the tests that matter most — duplicate delivery,
      # replay, and crash recovery.
      class PostgresLogTransport < Port
        Duplicate = Class.new(StandardError)

        # @return [String, nil] the log entry id, or nil if this outbox message
        #   was already published (a relay that crashed after publishing)
        def publish(topic:, key:, payload:, headers: {}, outbox_message_id: nil)
          partition = Transport.partition_for(key)

          entry = Internal::Models::EventLogEntry.new(
            topic: topic,
            partition_number: partition,
            position: Internal::Models::EventLogEntry.next_position(
              topic: topic, partition_number: partition
            ),
            partition_key: key.to_s,
            event_type: headers["event_type"] || headers[:event_type] || topic,
            event_version: headers["version"] || headers[:version] || 1,
            payload: payload,
            headers: headers,
            outbox_message_id: outbox_message_id,
            published_at: Time.current
          )

          entry.save!
          entry.id
        rescue ActiveRecord::RecordNotUnique => e
          # Two distinct races land here and they mean opposite things.
          #
          # The outbox-dedup index firing means this message is already in the
          # log — a relay republished after crashing between publish and mark.
          # That is the at-least-once path working, and it is not an error.
          #
          # The position index firing means another relay took this position
          # first. The message is NOT published; the caller must retry.
          raise Duplicate, "position taken" unless e.message.include?("outbox_dedup")

          nil
        end

        # Entries a group has not yet processed, across every partition, oldest
        # first. Partition order is not meaningful — only order *within* a
        # partition is, which is what INV-09 promises and all it promises.
        def read(group:, topic:, limit: 100)
          (0...Transport::PARTITIONS).flat_map do |partition|
            from = Internal::Models::EventLogCursor.position_for(
              consumer_group: group, topic: topic, partition_number: partition
            )

            Internal::Models::EventLogEntry
              .in_partition(topic, partition)
              .after(from)
              .limit(limit)
              .to_a
          end
        end

        def commit(group:, topic:, partition_number:, position:)
          Internal::Models::EventLogCursor.commit!(
            consumer_group: group, topic: topic,
            partition_number: partition_number, position: position
          )
        end

        # Move a group's cursor, forwards or backwards. Backwards is a replay;
        # forwards is skipping poison messages, which is a decision a human makes
        # and an audit record should exist for.
        def seek(group:, topic:, partition_number:, position:)
          cursor = Internal::Models::EventLogCursor.find_or_initialize_by(
            consumer_group: group, topic: topic, partition_number: partition_number
          )
          cursor.position = position
          cursor.committed_at = Time.current
          cursor.save!
          cursor
        end
      end
    end
  end
end
