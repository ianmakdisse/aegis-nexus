# frozen_string_literal: true

# Phase 5 — durable storage for the PostgreSQL transport (ADR-003).
#
# WHY THESE TABLES EXIST AND `consumer_offsets` DOES NOT COVER IT
#
# ADR-003 specifies two transports behind one port. Kafka partitions globally
# and its offsets are a fact about a broker partition — no tenant, which is why
# `consumer_offsets` is tenant-exempt. That exemption is correct *for Kafka*.
#
# The PostgreSQL transport cannot work that way. Its log is our own table, so
# row-level security governs it, and no application role may bypass RLS
# (INV-14). Consumption is therefore per tenant — exactly as the outbox relay
# already reads per tenant — and a cursor is per `(organization_id,
# consumer_group, topic, partition)`.
#
# So this is not a duplicate of `consumer_offsets`; it is the other transport's
# position tracking, with different semantics because the two transports have
# different isolation models. `consumer_offsets` stays unused until KafkaTransport
# is built in Phase 14.
class CreateEventLog < ActiveRecord::Migration[7.1]
  include Nexus::Migration::Tenancy

  def change
    # The durable log the relay publishes into and consumers read from. This —
    # not the outbox — is what replay reads: the outbox is a per-writer buffer
    # that is drained and reaped, while the log is the fan-out record.
    create_table :event_log_entries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :topic, null: false
      # Ordering is per-key, never global (INV-09). The partition is derived from
      # the partition key, so two events sharing a key always land in the same
      # partition and are read in the order they were written. Nothing may assume
      # ordering across partitions.
      t.integer :partition_number, null: false
      t.bigint :position, null: false
      t.string :partition_key, null: false
      t.string :event_type, null: false
      t.integer :event_version, null: false, default: 1
      t.jsonb :payload, null: false, default: {}
      t.jsonb :headers, null: false, default: {}
      t.uuid :outbox_message_id            # provenance; not a foreign key by design
      t.datetime :published_at, null: false
      t.timestamps
    end
    # The position is dense and monotonic within a tenant's partition. Unique so
    # a relay retry cannot write two entries at the same position — the log
    # would otherwise silently reorder under at-least-once publication.
    add_index :event_log_entries, %i[organization_id topic partition_number position],
              unique: true, name: "index_event_log_entries_position"
    # A relay that crashes after publishing but before marking the outbox row
    # republishes on restart. This index makes that duplicate detectable in one
    # lookup rather than trusting the relay to be crash-free.
    add_index :event_log_entries, %i[organization_id outbox_message_id],
              unique: true, where: "outbox_message_id IS NOT NULL",
              name: "index_event_log_entries_outbox_dedup"
    enable_tenant_rls! :event_log_entries

    # How far a consumer group has read. One row per tenant per partition, so a
    # slow tenant delays only itself.
    create_table :event_log_cursors, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :consumer_group, null: false
      t.string :topic, null: false
      t.integer :partition_number, null: false
      # Last position PROCESSED, not last read. The distinction matters on a
      # crash: re-reading a processed entry is harmless (the inbox dedupes),
      # skipping an unprocessed one is data loss.
      t.bigint :position, null: false, default: 0
      t.datetime :committed_at
      t.timestamps
    end
    add_index :event_log_cursors, %i[organization_id consumer_group topic partition_number],
              unique: true, name: "index_event_log_cursors_position"
    enable_tenant_rls! :event_log_cursors
  end
end
