# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_08_10_000011) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pgcrypto"
  enable_extension "plpgsql"

  create_table "agent_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "agent_version_id", null: false
    t.uuid "workflow_run_id"
    t.uuid "invoker_membership_id"
    t.uuid "invoker_service_identity_id"
    t.string "status", default: "running", null: false
    t.string "model"
    t.string "model_version"
    t.string "prompt_hash", null: false
    t.integer "tokens_in", default: 0, null: false
    t.integer "tokens_out", default: 0, null: false
    t.integer "cached_tokens", default: 0, null: false
    t.integer "cost_millicents", default: 0, null: false
    t.integer "latency_ms"
    t.integer "tool_call_count", default: 0, null: false
    t.integer "recursion_depth", default: 0, null: false
    t.jsonb "decision"
    t.decimal "confidence", precision: 5, scale: 4
    t.string "refusal_category"
    t.string "terminated_reason"
    t.string "trace_id"
    t.string "correlation_id"
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "agent_version_id"], name: "index_agent_executions_on_organization_id_and_agent_version_id"
    t.index ["organization_id", "started_at"], name: "index_agent_executions_on_organization_id_and_started_at"
    t.index ["organization_id", "terminated_reason"], name: "index_agent_executions_terminated", where: "(terminated_reason IS NOT NULL)"
    t.index ["organization_id", "workflow_run_id"], name: "index_agent_executions_on_organization_id_and_workflow_run_id"
  end

  create_table "agent_memories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "agent_id", null: false
    t.string "scope", default: "agent", null: false
    t.uuid "scope_id"
    t.string "key", null: false
    t.jsonb "content", default: {}, null: false
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "agent_id", "scope", "scope_id", "key"], name: "index_agent_memories_key", unique: true
    t.index ["organization_id", "expires_at"], name: "index_agent_memories_on_organization_id_and_expires_at"
  end

  create_table "agent_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "agent_id", null: false
    t.integer "version", null: false
    t.text "system_prompt", null: false
    t.string "prompt_checksum", null: false
    t.string "model_tier", default: "standard", null: false
    t.jsonb "tool_set", default: [], null: false
    t.jsonb "ceilings", default: {}, null: false
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "agent_id", "version"], name: "index_agent_versions_number", unique: true
  end

  create_table "agents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "status", default: "draft", null: false
    t.uuid "service_identity_id"
    t.uuid "created_by_membership_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "key"], name: "index_agents_on_organization_id_and_key", unique: true
  end

  create_table "approval_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "workflow_run_id", null: false
    t.string "step_key", null: false
    t.string "decision", default: "pending", null: false
    t.jsonb "context", default: {}, null: false
    t.uuid "assignee_team_id"
    t.uuid "decided_by_membership_id"
    t.text "reason"
    t.datetime "requested_at", null: false
    t.datetime "decided_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "decision", "expires_at"], name: "idx_on_organization_id_decision_expires_at_0b08498cbc"
    t.index ["organization_id", "workflow_run_id"], name: "index_approval_requests_on_organization_id_and_workflow_run_id"
  end

  create_table "audit_chains", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.bigint "start_position", null: false
    t.bigint "end_position", null: false
    t.string "head_hash", null: false
    t.integer "record_count", default: 0, null: false
    t.datetime "period_start", null: false
    t.datetime "period_end", null: false
    t.datetime "sealed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "end_position"], name: "index_audit_chains_seal", unique: true
  end

  create_table "audit_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "actor_kind", null: false
    t.uuid "actor_id"
    t.string "action", null: false
    t.string "resource_type", null: false
    t.uuid "resource_id"
    t.string "outcome", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "trace_id"
    t.string "correlation_id"
    t.bigint "chain_position", null: false
    t.string "prev_hash"
    t.string "hash", null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "actor_kind", "actor_id"], name: "idx_on_organization_id_actor_kind_actor_id_4f2b83cb43"
    t.index ["organization_id", "chain_position"], name: "index_audit_records_chain", unique: true
    t.index ["organization_id", "occurred_at"], name: "index_audit_records_on_organization_id_and_occurred_at"
    t.index ["organization_id", "resource_type", "resource_id"], name: "idx_on_organization_id_resource_type_resource_id_7ad0ba8277"
  end

  create_table "budgets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "scope", default: "organization", null: false
    t.uuid "scope_id"
    t.string "period", default: "monthly", null: false
    t.bigint "limit_millicents", null: false
    t.boolean "hard_stop", default: true, null: false
    t.datetime "starts_at", null: false
    t.datetime "ends_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "scope", "scope_id"], name: "index_budgets_scope", unique: true
  end

  create_table "connections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "integration_id", null: false
    t.string "external_account_id"
    t.string "status", default: "connected", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "connected_at", null: false
    t.uuid "connected_by_membership_id"
    t.datetime "last_verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "integration_id"], name: "index_connections_on_organization_id_and_integration_id"
  end

  create_table "consumer_offsets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "consumer_group", null: false
    t.string "topic", null: false
    t.integer "partition_number", null: false
    t.bigint "offset_value", default: 0, null: false
    t.datetime "committed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["consumer_group", "topic", "partition_number"], name: "index_consumer_offsets_position", unique: true
  end

  create_table "cost_rollups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "dimension", null: false
    t.uuid "dimension_id"
    t.datetime "period_start", null: false
    t.datetime "period_end", null: false
    t.bigint "tokens_in", default: 0, null: false
    t.bigint "tokens_out", default: 0, null: false
    t.bigint "cost_millicents", default: 0, null: false
    t.integer "execution_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "dimension", "dimension_id", "period_start"], name: "index_cost_rollups_period", unique: true
  end

  create_table "dead_letter_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "consumer_group", null: false
    t.string "event_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "error_class"
    t.text "error_message"
    t.integer "attempts", default: 0, null: false
    t.datetime "failed_at", null: false
    t.datetime "replayed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "failed_at"], name: "index_dead_letter_messages_on_organization_id_and_failed_at"
    t.index ["organization_id", "replayed_at"], name: "index_dead_letter_messages_on_organization_id_and_replayed_at"
  end

  create_table "document_chunks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "document_id", null: false
    t.integer "ordinal", null: false
    t.text "content", null: false
    t.integer "token_count"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "document_id", "ordinal"], name: "index_document_chunks_ordinal", unique: true
  end

  create_table "documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "knowledge_namespace_id", null: false
    t.string "title", null: false
    t.string "source_uri"
    t.string "content_type"
    t.bigint "byte_size"
    t.string "checksum"
    t.string "status", default: "pending", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "ingested_at"
    t.uuid "uploaded_by_membership_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "checksum"], name: "index_documents_on_organization_id_and_checksum"
    t.index ["organization_id", "knowledge_namespace_id"], name: "index_documents_on_organization_id_and_knowledge_namespace_id"
    t.index ["organization_id", "status"], name: "index_documents_on_organization_id_and_status"
  end

  create_table "encrypted_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "connection_id", null: false
    t.text "ciphertext", null: false
    t.string "key_id", null: false
    t.string "algorithm", default: "aes-256-gcm", null: false
    t.datetime "rotated_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "connection_id"], name: "idx_on_organization_id_connection_id_0481f2f5ab"
    t.index ["organization_id", "expires_at"], name: "index_encrypted_credentials_on_organization_id_and_expires_at"
  end

  create_table "endpoint_health", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "integration_id", null: false
    t.string "state", default: "closed", null: false
    t.integer "failure_count", default: 0, null: false
    t.integer "success_count", default: 0, null: false
    t.datetime "opened_at"
    t.datetime "half_opened_at"
    t.string "last_error"
    t.datetime "last_success_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "integration_id"], name: "index_endpoint_health_per_integration", unique: true
  end

  create_table "event_log_cursors", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "consumer_group", null: false
    t.string "topic", null: false
    t.integer "partition_number", null: false
    t.bigint "position", default: 0, null: false
    t.datetime "committed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "consumer_group", "topic", "partition_number"], name: "index_event_log_cursors_position", unique: true
  end

  create_table "event_log_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "topic", null: false
    t.integer "partition_number", null: false
    t.bigint "position", null: false
    t.string "partition_key", null: false
    t.string "event_type", null: false
    t.integer "event_version", default: 1, null: false
    t.jsonb "payload", default: {}, null: false
    t.jsonb "headers", default: {}, null: false
    t.uuid "outbox_message_id"
    t.datetime "published_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "outbox_message_id"], name: "index_event_log_entries_outbox_dedup", unique: true, where: "(outbox_message_id IS NOT NULL)"
    t.index ["organization_id", "topic", "partition_number", "position"], name: "index_event_log_entries_position", unique: true
  end

  create_table "event_store_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "stream_id", null: false
    t.string "stream_type", null: false
    t.bigint "sequence", null: false
    t.string "event_type", null: false
    t.integer "event_version", default: 1, null: false
    t.jsonb "payload", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "stream_id", "sequence"], name: "index_event_store_events_stream_position", unique: true
    t.index ["organization_id", "stream_type", "occurred_at"], name: "idx_on_organization_id_stream_type_occurred_at_c022ed23e1"
  end

  create_table "event_store_snapshots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "stream_id", null: false
    t.string "stream_type", null: false
    t.bigint "sequence", null: false
    t.jsonb "state", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "stream_id", "sequence"], name: "index_event_store_snapshots_position", unique: true
  end

  create_table "event_type_registry", primary_key: ["key", "version"], force: :cascade do |t|
    t.string "key", null: false
    t.integer "version", default: 1, null: false
    t.jsonb "schema", default: {}, null: false
    t.string "status", default: "active", null: false
    t.string "owning_context", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "feature_flags", primary_key: "key", id: :string, force: :cascade do |t|
    t.boolean "enabled", default: false, null: false
    t.jsonb "conditions", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "grants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "role_id", null: false
    t.uuid "membership_id"
    t.uuid "service_identity_id"
    t.jsonb "conditions", default: {}, null: false
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "membership_id"], name: "index_grants_on_organization_id_and_membership_id"
    t.index ["organization_id", "service_identity_id"], name: "index_grants_on_organization_id_and_service_identity_id"
    t.check_constraint "membership_id IS NOT NULL AND service_identity_id IS NULL OR membership_id IS NULL AND service_identity_id IS NOT NULL", name: "grants_exactly_one_subject"
  end

  create_table "inbox_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "consumer_group", null: false
    t.string "dedup_key", null: false
    t.string "event_type"
    t.datetime "processed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "consumer_group", "dedup_key"], name: "index_inbox_messages_dedup", unique: true
  end

  create_table "ingested_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "source", null: false
    t.string "external_id"
    t.string "idempotency_key"
    t.boolean "signature_verified", default: false, null: false
    t.jsonb "payload", default: {}, null: false
    t.jsonb "headers", default: {}, null: false
    t.string "status", default: "stored", null: false
    t.string "rejection_reason"
    t.string "trace_id"
    t.string "correlation_id"
    t.datetime "received_at", null: false
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "received_at"], name: "index_ingested_events_on_organization_id_and_received_at"
    t.index ["organization_id", "source", "external_id"], name: "index_ingested_events_replay_protection", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["organization_id", "status"], name: "index_ingested_events_on_organization_id_and_status"
  end

  create_table "ingestion_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "document_id", null: false
    t.string "status", default: "queued", null: false
    t.string "stage"
    t.integer "attempts", default: 0, null: false
    t.string "last_error"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "document_id"], name: "index_ingestion_jobs_on_organization_id_and_document_id"
    t.index ["organization_id", "status"], name: "index_ingestion_jobs_on_organization_id_and_status"
  end

  create_table "integrations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "connector_key", null: false
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "connector_key"], name: "index_integrations_on_organization_id_and_connector_key", unique: true
  end

  create_table "knowledge_namespaces", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.string "classification", default: "internal", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "key"], name: "index_knowledge_namespaces_on_organization_id_and_key", unique: true
  end

  create_table "memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "user_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "invited_at"
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "user_id"], name: "index_memberships_on_organization_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "notification_channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.jsonb "config", default: {}, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "kind"], name: "index_notification_channels_on_organization_id_and_kind"
  end

  create_table "notification_deliveries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "notification_channel_id", null: false
    t.uuid "subscription_id"
    t.string "dedup_key", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.integer "attempts", default: 0, null: false
    t.string "last_error"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "dedup_key"], name: "index_notification_deliveries_dedup", unique: true
    t.index ["organization_id", "status"], name: "index_notification_deliveries_on_organization_id_and_status"
  end

  create_table "org_placements", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "from_tier"
    t.string "to_tier", null: false
    t.string "from_database_key"
    t.string "to_database_key"
    t.string "status", default: "pending", null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.jsonb "verification", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "created_at"], name: "index_org_placements_on_organization_id_and_created_at"
  end

  create_table "organizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "status", default: "active", null: false
    t.string "tier", default: "pool", null: false
    t.string "region_code", null: false
    t.string "database_key"
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
    t.index ["tier", "region_code"], name: "index_organizations_on_tier_and_region_code"
    t.check_constraint "tier::text = 'pool'::text AND database_key IS NULL OR tier::text = 'dedicated'::text AND database_key IS NOT NULL", name: "organizations_placement_consistent"
  end

  create_table "outbox_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "event_type", null: false
    t.integer "event_version", default: 1, null: false
    t.string "partition_key", null: false
    t.jsonb "payload", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.integer "attempts", default: 0, null: false
    t.string "last_error"
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "created_at"], name: "index_outbox_messages_unpublished", where: "(published_at IS NULL)"
    t.index ["organization_id", "partition_key"], name: "index_outbox_messages_on_organization_id_and_partition_key"
  end

  create_table "permissions", primary_key: "key", id: :string, force: :cascade do |t|
    t.string "resource_type", null: false
    t.string "action", null: false
    t.string "risk_tier", default: "LOW", null: false
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "policies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "name", null: false
    t.string "effect", default: "deny", null: false
    t.jsonb "matcher", default: {}, null: false
    t.integer "priority", default: 100, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "priority"], name: "index_policies_on_organization_id_and_priority"
  end

  create_table "regions", primary_key: "code", id: :string, force: :cascade do |t|
    t.string "name", null: false
    t.string "residency_zone", null: false
    t.boolean "accepts_new_tenants", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "reservations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "budget_id", null: false
    t.uuid "agent_execution_id"
    t.bigint "amount_millicents", null: false
    t.string "state", default: "held", null: false
    t.datetime "expires_at", null: false
    t.datetime "settled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "budget_id", "state"], name: "index_reservations_outstanding"
    t.index ["organization_id", "expires_at"], name: "index_reservations_expiring", where: "((state)::text = 'held'::text)"
  end

  create_table "role_permissions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "role_id", null: false
    t.string "permission_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_role_permissions_on_organization_id"
    t.index ["role_id", "permission_key"], name: "index_role_permissions_on_role_id_and_permission_key", unique: true
  end

  create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.boolean "system", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "key"], name: "index_roles_on_organization_id_and_key", unique: true
  end

  create_table "run_leases", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "workflow_run_id", null: false
    t.string "worker_id", null: false
    t.bigint "fence_token", default: 1, null: false
    t.datetime "acquired_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "expires_at"], name: "index_run_leases_on_organization_id_and_expires_at"
    t.index ["organization_id", "workflow_run_id"], name: "index_run_leases_one_per_run", unique: true
  end

  create_table "scheduled_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "kind", null: false
    t.uuid "subject_id"
    t.jsonb "payload", default: {}, null: false
    t.datetime "run_at", null: false
    t.string "status", default: "pending", null: false
    t.string "claimed_by"
    t.datetime "claimed_until"
    t.integer "attempts", default: 0, null: false
    t.string "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "run_at"], name: "index_scheduled_jobs_due", where: "((status)::text = 'pending'::text)"
  end

  create_table "service_identities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "name", null: false
    t.string "kind", null: false
    t.string "token_digest", null: false
    t.jsonb "scopes", default: [], null: false
    t.datetime "expires_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "name"], name: "index_service_identities_on_organization_id_and_name", unique: true
    t.index ["token_digest"], name: "index_service_identities_on_token_digest", unique: true
  end

  create_table "sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "user_id", null: false
    t.string "refresh_token_digest", null: false
    t.string "user_agent"
    t.inet "ip_address"
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.uuid "family_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["family_id"], name: "index_sessions_on_family_id"
    t.index ["organization_id", "user_id"], name: "index_sessions_on_organization_id_and_user_id"
    t.index ["refresh_token_digest"], name: "index_sessions_on_refresh_token_digest", unique: true
  end

  create_table "step_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "workflow_run_id", null: false
    t.string "step_key", null: false
    t.string "step_type", null: false
    t.integer "attempt", default: 1, null: false
    t.string "status", default: "running", null: false
    t.jsonb "input", default: {}, null: false
    t.jsonb "output"
    t.jsonb "error"
    t.string "idempotency_key", null: false
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "idempotency_key"], name: "index_step_executions_idempotency", unique: true
    t.index ["organization_id", "workflow_run_id", "step_key", "attempt"], name: "index_step_executions_attempt", unique: true
  end

  create_table "subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "notification_channel_id", null: false
    t.uuid "membership_id"
    t.string "event_pattern", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "event_pattern"], name: "index_subscriptions_on_organization_id_and_event_pattern"
    t.index ["organization_id", "notification_channel_id"], name: "idx_on_organization_id_notification_channel_id_a88bfbcbb0"
  end

  create_table "team_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "team_id", null: false
    t.uuid "membership_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_team_memberships_on_organization_id"
    t.index ["team_id", "membership_id"], name: "index_team_memberships_on_team_id_and_membership_id", unique: true
  end

  create_table "teams", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "name"], name: "index_teams_on_organization_id_and_name", unique: true
  end

  create_table "tool_catalog_templates", primary_key: "key", id: :string, force: :cascade do |t|
    t.string "name", null: false
    t.string "category", null: false
    t.jsonb "argument_schema", default: {}, null: false
    t.string "default_risk_tier", default: "LOW", null: false
    t.boolean "requires_approval_by_default", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "tool_invocations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "agent_execution_id", null: false
    t.uuid "tool_registration_id", null: false
    t.jsonb "arguments", default: {}, null: false
    t.jsonb "result"
    t.boolean "authorized", default: false, null: false
    t.string "denial_reason"
    t.string "status", default: "proposed", null: false
    t.string "idempotency_key", null: false
    t.integer "latency_ms"
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "agent_execution_id"], name: "idx_on_organization_id_agent_execution_id_31df264980"
    t.index ["organization_id", "authorized"], name: "index_tool_invocations_denials", where: "(authorized = false)"
    t.index ["organization_id", "idempotency_key"], name: "index_tool_invocations_idempotency", unique: true
  end

  create_table "tool_registrations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "key", null: false
    t.string "template_key"
    t.string "name", null: false
    t.jsonb "argument_schema", default: {}, null: false
    t.string "risk_tier", default: "LOW", null: false
    t.boolean "requires_approval", default: false, null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "connection_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "key"], name: "index_tool_registrations_on_organization_id_and_key", unique: true
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest"
    t.string "full_name"
    t.string "status", default: "active", null: false
    t.datetime "email_verified_at"
    t.string "mfa_secret_ciphertext"
    t.datetime "mfa_enabled_at"
    t.datetime "last_authenticated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
  end

  create_table "webhook_deliveries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "webhook_endpoint_id"
    t.string "direction", null: false
    t.string "target_url"
    t.jsonb "request", default: {}, null: false
    t.jsonb "response"
    t.integer "status_code"
    t.integer "attempts", default: 1, null: false
    t.string "last_error"
    t.datetime "next_attempt_at"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "created_at"], name: "index_webhook_deliveries_on_organization_id_and_created_at"
    t.index ["organization_id", "next_attempt_at"], name: "index_webhook_deliveries_pending", where: "(delivered_at IS NULL)"
  end

  create_table "webhook_endpoints", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "integration_id", null: false
    t.string "path_token", null: false
    t.string "secret_digest", null: false
    t.string "signature_algorithm", default: "hmac-sha256", null: false
    t.integer "freshness_window_seconds", default: 300, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "integration_id"], name: "index_webhook_endpoints_on_organization_id_and_integration_id"
    t.index ["path_token"], name: "index_webhook_endpoints_on_path_token", unique: true
  end

  create_table "workflow_definitions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "status", default: "draft", null: false
    t.uuid "created_by_membership_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "key"], name: "index_workflow_definitions_on_organization_id_and_key", unique: true
  end

  create_table "workflow_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "workflow_version_id", null: false
    t.string "status", default: "pending", null: false
    t.jsonb "input", default: {}, null: false
    t.jsonb "output"
    t.jsonb "error"
    t.bigint "sequence", default: 0, null: false
    t.string "idempotency_key"
    t.string "trigger_source"
    t.string "trace_id"
    t.string "correlation_id"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "idempotency_key"], name: "index_workflow_runs_idempotency", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["organization_id", "status", "started_at"], name: "idx_on_organization_id_status_started_at_6ea4c87608"
    t.index ["organization_id", "workflow_version_id"], name: "index_workflow_runs_on_organization_id_and_workflow_version_id"
  end

  create_table "workflow_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id", null: false
    t.uuid "workflow_definition_id", null: false
    t.integer "version", null: false
    t.jsonb "definition", default: {}, null: false
    t.string "checksum", null: false
    t.datetime "published_at"
    t.uuid "published_by_membership_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "workflow_definition_id", "version"], name: "index_workflow_versions_number", unique: true
  end

  add_foreign_key "grants", "memberships"
  add_foreign_key "grants", "organizations"
  add_foreign_key "grants", "roles"
  add_foreign_key "grants", "service_identities"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "org_placements", "organizations"
  add_foreign_key "organizations", "regions", column: "region_code", primary_key: "code"
  add_foreign_key "policies", "organizations"
  add_foreign_key "role_permissions", "organizations"
  add_foreign_key "role_permissions", "permissions", column: "permission_key", primary_key: "key"
  add_foreign_key "role_permissions", "roles"
  add_foreign_key "roles", "organizations"
  add_foreign_key "service_identities", "organizations"
  add_foreign_key "sessions", "organizations"
  add_foreign_key "sessions", "users"
  add_foreign_key "team_memberships", "memberships"
  add_foreign_key "team_memberships", "organizations"
  add_foreign_key "team_memberships", "teams"
  add_foreign_key "teams", "organizations"
end
