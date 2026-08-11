# frozen_string_literal: true

# Phase 4 — the Integrations context.
#
# This is where the platform touches systems it does not control, so the tables
# are shaped around two assumptions that are always true and usually ignored:
# the outside world is slow, and the outside world is down.
#
# Hence `endpoint_health` (a circuit breaker with state, not a retry loop) and
# `webhook_deliveries` (an attempt log, not a boolean "sent" flag).
class CreateIntegrations < ActiveRecord::Migration[7.1]
  include Nexus::Migration::Tenancy

  def change
    create_table :integrations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :connector_key, null: false               # stripe | github | slack…
      t.string :name, null: false
      t.string :status, null: false, default: "active"   # active | disabled
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end
    add_index :integrations, %i[organization_id connector_key], unique: true
    enable_tenant_rls! :integrations

    create_table :connections, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :integration_id, null: false
      t.string :external_account_id
      t.string :status, null: false, default: "connected" # connected | expired | revoked
      t.jsonb :metadata, null: false, default: {}
      t.datetime :connected_at, null: false
      t.uuid :connected_by_membership_id
      t.datetime :last_verified_at
      t.timestamps
    end
    add_index :connections, %i[organization_id integration_id]
    enable_tenant_rls! :connections

    # INV-18. The plaintext credential exists in memory at point of use and
    # nowhere else — not in a log, a trace, an event, or a prompt.
    #
    # `key_id` names the key that encrypted this row rather than assuming one
    # global key. That is what makes rotation possible without re-encrypting
    # everything at once, and what makes crypto-shredding a tenant's data a
    # matter of destroying a key rather than finding every row (NFR-602).
    #
    # ADR-005 calls credentials the clearest example of state that must NOT be
    # event-sourced: an append-only log of secrets cannot be redacted.
    create_table :encrypted_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :connection_id, null: false
      t.text :ciphertext, null: false
      t.string :key_id, null: false
      t.string :algorithm, null: false, default: "aes-256-gcm"
      t.datetime :rotated_at
      t.datetime :expires_at
      t.timestamps
    end
    add_index :encrypted_credentials, %i[organization_id connection_id]
    add_index :encrypted_credentials, %i[organization_id expires_at]
    enable_tenant_rls! :encrypted_credentials

    # Inbound. `path_token` is the unguessable part of the receive URL and
    # `secret_digest` verifies the signature — the URL being secret is not a
    # security control, which is why both exist.
    create_table :webhook_endpoints, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :integration_id, null: false
      t.string :path_token, null: false
      t.string :secret_digest, null: false
      t.string :signature_algorithm, null: false, default: "hmac-sha256"
      t.integer :freshness_window_seconds, null: false, default: 300  # replay protection
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    # Global unique: the receive URL is resolved before a tenant is known, which
    # is the same bootstrapping problem machine tokens have (ADR-011).
    add_index :webhook_endpoints, :path_token, unique: true
    add_index :webhook_endpoints, %i[organization_id integration_id]
    enable_tenant_rls! :webhook_endpoints

    # One row per ATTEMPT, in both directions. A delivery that succeeded on the
    # fourth try is a different operational fact from one that succeeded first
    # time, and a boolean cannot tell them apart.
    create_table :webhook_deliveries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :webhook_endpoint_id
      t.string :direction, null: false                   # inbound | outbound
      t.string :target_url
      t.jsonb :request, null: false, default: {}
      t.jsonb :response
      t.integer :status_code
      t.integer :attempts, null: false, default: 1
      t.string :last_error
      t.datetime :next_attempt_at
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :webhook_deliveries, %i[organization_id created_at]
    add_index :webhook_deliveries, %i[organization_id next_attempt_at],
              where: "delivered_at IS NULL", name: "index_webhook_deliveries_pending"
    enable_tenant_rls! :webhook_deliveries

    # The circuit breaker, made durable. In memory it would reset on every
    # deploy — and a breaker that forgets it was open re-hammers a failing
    # dependency exactly when it is least able to take it.
    create_table :endpoint_health, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :integration_id, null: false
      t.string :state, null: false, default: "closed"    # closed | open | half_open
      t.integer :failure_count, null: false, default: 0
      t.integer :success_count, null: false, default: 0
      t.datetime :opened_at
      t.datetime :half_opened_at
      t.string :last_error
      t.datetime :last_success_at
      t.timestamps
    end
    add_index :endpoint_health, %i[organization_id integration_id], unique: true,
              name: "index_endpoint_health_per_integration"
    enable_tenant_rls! :endpoint_health
  end
end
