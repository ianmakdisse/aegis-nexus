# frozen_string_literal: true

# Phase 4 — the Events context (ADR-003, ADR-005).
#
# Two mechanisms live here and are constantly confused, so the tables are
# grouped to keep them apart:
#
#   The event LOG      ingested_events → outbox_messages → inbox_messages
#                      fan-out, replay, per-key ordering
#   The event STORE    event_store_events + snapshots
#                      the authoritative history of four aggregates (ADR-005)
#
# The broker is not in either list, on purpose: it is transport. The event store
# is the replay source, never Kafka (ADR-003).
class CreateEventBackbone < ActiveRecord::Migration[7.1]
  include Nexus::Migration::Tenancy

  def change
    # ---- Ingestion (FR-201, FR-202) ---------------------------------------
    # A 2xx to a provider means "durably stored", never "processed". That is
    # why `status` starts at `stored` and processing is a separate transition:
    # conflating them is how a provider's retry budget gets spent on our
    # downstream outage.
    create_table :ingested_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :source, null: false              # connector key: stripe, github…
      t.string :external_id                      # the provider's own event id
      t.string :idempotency_key
      t.boolean :signature_verified, null: false, default: false
      t.jsonb :payload, null: false, default: {}
      t.jsonb :headers, null: false, default: {}
      t.string :status, null: false, default: "stored"   # stored | processed | rejected
      t.string :rejection_reason
      t.string :trace_id
      t.string :correlation_id
      t.datetime :received_at, null: false
      t.datetime :processed_at
      t.timestamps
    end
    add_index :ingested_events, %i[organization_id received_at]
    add_index :ingested_events, %i[organization_id status]
    # Replay protection (FR-201). A provider redelivering the same event must
    # not produce a second ingestion — this index is the enforcement, not the
    # application's memory of what it has seen.
    add_index :ingested_events, %i[organization_id source external_id],
              unique: true, where: "external_id IS NOT NULL",
              name: "index_ingested_events_replay_protection"
    enable_tenant_rls! :ingested_events

    # ---- The event store (ADR-005) ----------------------------------------
    #
    # NOT partitioned by time, deliberately, and this is a refinement of
    # ADR-002's partitioning plan rather than an oversight — see ADR-012.
    # PostgreSQL requires a unique constraint on a partitioned table to include
    # every partitioning column, and the optimistic-concurrency guarantee below
    # is `UNIQUE (organization_id, stream_id, sequence)`. Adding `occurred_at`
    # to that index would permit two events at the same sequence, which is the
    # one thing the event store may never allow.
    create_table :event_store_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :stream_id, null: false                     # the aggregate instance
      t.string :stream_type, null: false                 # WorkflowRun | AgentExecution | ApprovalRequest | AuditTrail
      t.bigint :sequence, null: false                    # per-stream, gapless, from 1
      t.string :event_type, null: false
      t.integer :event_version, null: false, default: 1  # INV-10
      t.jsonb :payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}        # trace_id, correlation_id, causation_id, actor
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    # Optimistic concurrency: two writers appending sequence N to one stream is
    # a conflict the database rejects, not a race the application hopes to win.
    add_index :event_store_events, %i[organization_id stream_id sequence], unique: true,
              name: "index_event_store_events_stream_position"
    add_index :event_store_events, %i[organization_id stream_type occurred_at]
    enable_tenant_rls! :event_store_events

    # A snapshot is a CACHE (ADR-005). Losing every row here costs replay time
    # and nothing else, which is why there is no uniqueness beyond position and
    # no foreign key to the events it summarizes.
    create_table :event_store_snapshots, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :stream_id, null: false
      t.string :stream_type, null: false
      t.bigint :sequence, null: false                    # state as of this position
      t.jsonb :state, null: false, default: {}
      t.timestamps
    end
    add_index :event_store_snapshots, %i[organization_id stream_id sequence], unique: true,
              name: "index_event_store_snapshots_position"
    enable_tenant_rls! :event_store_snapshots

    # ---- Outbox (INV-04) ---------------------------------------------------
    #
    # Written in the SAME transaction as the domain state it describes. That is
    # the whole point: there is no window in which the state changed and the
    # event did not.
    #
    # The relay reads this table per tenant rather than across all of them. It
    # would be simpler to scan globally, but that requires a role that bypasses
    # RLS, and INV-14 has no such role. Iterating tenants also gives per-tenant
    # fairness for free — one tenant's backlog cannot starve everyone else's.
    create_table :outbox_messages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :event_type, null: false
      t.integer :event_version, null: false, default: 1
      t.string :partition_key, null: false               # INV-09: ordering is per-key
      t.jsonb :payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.datetime :published_at
      t.timestamps
    end
    # The relay's working index: unpublished rows, oldest first, within a tenant.
    # Partial, because published rows are the overwhelming majority and none of
    # them are ever read this way.
    add_index :outbox_messages, %i[organization_id created_at],
              where: "published_at IS NULL", name: "index_outbox_messages_unpublished"
    add_index :outbox_messages, %i[organization_id partition_key]
    enable_tenant_rls! :outbox_messages

    # ---- Inbox (INV-05) ----------------------------------------------------
    #
    # At-least-once delivery is the substrate, not a defect. This table is what
    # makes duplicates harmless: a handler runs only if its dedup key is new.
    create_table :inbox_messages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :consumer_group, null: false
      t.string :dedup_key, null: false                   # derived from durable identifiers
      t.string :event_type
      t.datetime :processed_at, null: false
      t.timestamps
    end
    add_index :inbox_messages, %i[organization_id consumer_group dedup_key], unique: true,
              name: "index_inbox_messages_dedup"
    enable_tenant_rls! :inbox_messages

    # ---- Dead letters ------------------------------------------------------
    # A message that cannot be handled is kept with its error, not dropped. The
    # replay path is the reason `payload` is stored in full.
    create_table :dead_letter_messages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :consumer_group, null: false
      t.string :event_type, null: false
      t.jsonb :payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.string :error_class
      t.text :error_message
      t.integer :attempts, null: false, default: 0
      t.datetime :failed_at, null: false
      t.datetime :replayed_at
      t.timestamps
    end
    add_index :dead_letter_messages, %i[organization_id failed_at]
    add_index :dead_letter_messages, %i[organization_id replayed_at]
    enable_tenant_rls! :dead_letter_messages

    # ---- Platform-global infrastructure (INV-13 exemptions, ADR-012) -------

    # A consumer group's position in a partition of the shared backbone. There
    # is no tenant here: an offset is a fact about transport, and forcing a
    # tenant onto it would mean one offset per tenant per partition, which is
    # not what an offset is.
    create_table :consumer_offsets, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :consumer_group, null: false
      t.string :topic, null: false
      t.integer :partition_number, null: false
      t.bigint :offset_value, null: false, default: 0
      t.datetime :committed_at
      t.timestamps
    end
    add_index :consumer_offsets, %i[consumer_group topic partition_number], unique: true,
              name: "index_consumer_offsets_position"

    # The event vocabulary (INV-10). Global for the same reason `permissions`
    # is: it describes the software, not a tenant. Versions accumulate and are
    # never deleted while any stored event still uses them.
    create_table :event_type_registry, id: false do |t|
      t.string :key, null: false                         # workflow.run.started
      t.integer :version, null: false, default: 1
      t.jsonb :schema, null: false, default: {}
      t.string :status, null: false, default: "active"   # active | deprecated
      t.string :owning_context, null: false
      t.timestamps
    end
    execute "ALTER TABLE event_type_registry ADD PRIMARY KEY (key, version);"
  end
end
