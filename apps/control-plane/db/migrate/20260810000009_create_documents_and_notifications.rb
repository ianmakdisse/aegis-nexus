# frozen_string_literal: true

# Phase 4 — the Documents/Knowledge and Notifications contexts.
#
# DELIBERATELY MISSING: `chunk_embeddings`.
#
# Two independent reasons, either of which is sufficient (see ADR-012):
#
#   1. Unresolved question Q4 — embedding model and dimensionality — is still
#      open. A `vector(N)` column IS that decision: N is fixed at DDL time and
#      changing it later rewrites every row. Creating the table now would
#      resolve Q4 by accident, in a migration, which is exactly what the
#      project's own rule forbids ("an unresolved question that starts blocking
#      implementation gets an ADR, not a hallway decision").
#   2. The `vector` extension is not available on this machine at all, so the
#      table could not be created here even if Q4 were settled.
#
# Everything else in the retrieval path is built, so the gap is one column in
# one table rather than a missing subsystem.
class CreateDocumentsAndNotifications < ActiveRecord::Migration[7.1]
  include Nexus::Migration::Tenancy

  def change
    # ---- Documents / Knowledge (ADR-008) ----------------------------------

    # A retrieval boundary. Two namespaces in one tenant must not see each
    # other's chunks — "which documents may this agent retrieve from" is an
    # authorization question, and this is the noun it attaches to.
    create_table :knowledge_namespaces, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.string :classification, null: false, default: "internal"  # public | internal | confidential
      t.timestamps
    end
    add_index :knowledge_namespaces, %i[organization_id key], unique: true
    enable_tenant_rls! :knowledge_namespaces

    create_table :documents, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :knowledge_namespace_id, null: false
      t.string :title, null: false
      t.string :source_uri                               # object storage key; bytes live there
      t.string :content_type
      t.bigint :byte_size
      t.string :checksum                                 # re-ingesting identical bytes is a no-op
      t.string :status, null: false, default: "pending"  # pending | ingested | failed | deleted
      t.jsonb :metadata, null: false, default: {}
      t.datetime :ingested_at
      t.uuid :uploaded_by_membership_id
      t.timestamps
    end
    add_index :documents, %i[organization_id knowledge_namespace_id]
    add_index :documents, %i[organization_id status]
    add_index :documents, %i[organization_id checksum]
    enable_tenant_rls! :documents

    # Chunks carry their own organization_id rather than reaching it through
    # `documents`. Denormalized on purpose: RLS predicates must not require a
    # join, or the isolation guarantee depends on the query plan.
    create_table :document_chunks, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :document_id, null: false
      t.integer :ordinal, null: false
      t.text :content, null: false
      t.integer :token_count
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :document_chunks, %i[organization_id document_id ordinal], unique: true,
              name: "index_document_chunks_ordinal"
    enable_tenant_rls! :document_chunks

    create_table :ingestion_jobs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :document_id, null: false
      t.string :status, null: false, default: "queued"   # queued | running | succeeded | failed
      t.string :stage                                    # fetch | extract | chunk | embed
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :ingestion_jobs, %i[organization_id status]
    add_index :ingestion_jobs, %i[organization_id document_id]
    enable_tenant_rls! :ingestion_jobs

    # ---- Notifications -----------------------------------------------------

    create_table :notification_channels, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :kind, null: false                        # email | slack | webhook | in_app
      t.string :name, null: false
      t.jsonb :config, null: false, default: {}          # no secrets — those are credentials
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :notification_channels, %i[organization_id kind]
    enable_tenant_rls! :notification_channels

    create_table :subscriptions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :notification_channel_id, null: false
      t.uuid :membership_id                              # null = a channel-wide subscription
      t.string :event_pattern, null: false               # workflow.run.failed, agent.*
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :subscriptions, %i[organization_id event_pattern]
    add_index :subscriptions, %i[organization_id notification_channel_id]
    enable_tenant_rls! :subscriptions

    # `dedup_key` is what stops at-least-once delivery from becoming
    # at-least-once *notification*. Duplicate events are harmless; duplicate
    # pages at 3am are how alerting gets muted (INV-05, INV-24).
    create_table :notification_deliveries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :notification_channel_id, null: false
      t.uuid :subscription_id
      t.string :dedup_key, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "pending"  # pending | sent | failed | suppressed
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :notification_deliveries, %i[organization_id dedup_key], unique: true,
              name: "index_notification_deliveries_dedup"
    add_index :notification_deliveries, %i[organization_id status]
    enable_tenant_rls! :notification_deliveries
  end
end
