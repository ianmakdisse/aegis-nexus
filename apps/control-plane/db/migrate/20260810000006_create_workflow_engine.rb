# frozen_string_literal: true

# Phase 4 — the Workflows context (ADR-006, the highest-risk decision in the set).
#
# Four properties are encoded in these tables rather than in the engine's code,
# because an engine can be rewritten and a schema cannot:
#
#   1. A run is pinned to a workflow VERSION, never to a definition (INV-12).
#      Editing a definition cannot reach an in-flight run.
#   2. Every step attempt is a NEW immutable row. Attempts are history, not a
#      counter that gets incremented over the top of what happened.
#   3. Workers hold LEASES that expire, not locks that don't survive a crash.
#      Expiry is the database's clock — never the worker's.
#   4. A waiting run costs one indexed row and zero workers. Sleeping is a
#      state, not a held thread.
class CreateWorkflowEngine < ActiveRecord::Migration[7.1]
  include Nexus::Migration::Tenancy

  def change
    # Tenant-authored, so this is data with platform-enforced governance rather
    # than deployed code — the argument ADR-006 rests on.
    create_table :workflow_definitions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: "draft"    # draft | active | archived
      t.uuid :created_by_membership_id
      t.timestamps
    end
    add_index :workflow_definitions, %i[organization_id key], unique: true
    enable_tenant_rls! :workflow_definitions

    # An immutable published version. `definition` holds the step graph; once
    # published it is never edited, because runs point at it (INV-12).
    create_table :workflow_versions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :workflow_definition_id, null: false
      t.integer :version, null: false
      t.jsonb :definition, null: false, default: {}
      t.string :checksum, null: false                    # detects a mutated version row
      t.datetime :published_at
      t.uuid :published_by_membership_id
      t.timestamps
    end
    add_index :workflow_versions, %i[organization_id workflow_definition_id version],
              unique: true, name: "index_workflow_versions_number"
    enable_tenant_rls! :workflow_versions

    # Event-sourced aggregate (ADR-005): the history IS the requirement, because
    # "why did this run do that" must be answerable six months later.
    create_table :workflow_runs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :workflow_version_id, null: false           # pinned — INV-12
      t.string :status, null: false, default: "pending"
      # pending | running | sleeping | waiting_approval | succeeded | failed | cancelled
      t.jsonb :input, null: false, default: {}
      t.jsonb :output
      t.jsonb :error
      t.bigint :sequence, null: false, default: 0        # last applied event position
      t.string :idempotency_key                          # INV-05: same trigger, same run
      t.string :trigger_source                           # event | api | schedule | manual
      t.string :trace_id
      t.string :correlation_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :workflow_runs, %i[organization_id status started_at]
    add_index :workflow_runs, %i[organization_id workflow_version_id]
    add_index :workflow_runs, %i[organization_id idempotency_key],
              unique: true, where: "idempotency_key IS NOT NULL",
              name: "index_workflow_runs_idempotency"
    enable_tenant_rls! :workflow_runs

    # One row per ATTEMPT. A retry does not overwrite the failure it is retrying:
    # the previous row is the evidence of what went wrong, and overwriting it is
    # how a flaky step becomes an unexplainable one.
    create_table :step_executions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :workflow_run_id, null: false
      t.string :step_key, null: false
      t.string :step_type, null: false                   # http | agent | approval | wait | branch…
      t.integer :attempt, null: false, default: 1
      t.string :status, null: false, default: "running"
      t.jsonb :input, null: false, default: {}
      t.jsonb :output
      t.jsonb :error
      # Derived from durable identifiers (run id + step key + attempt), never
      # from a timestamp or a random value — a key that changes on retry
      # defeats the deduplication it exists for.
      t.string :idempotency_key, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end
    add_index :step_executions, %i[organization_id workflow_run_id step_key attempt],
              unique: true, name: "index_step_executions_attempt"
    add_index :step_executions, %i[organization_id idempotency_key], unique: true,
              name: "index_step_executions_idempotency"
    enable_tenant_rls! :step_executions

    # Event-sourced aggregate. A suspension may last days, so this row IS the
    # waiting run — nothing is held in memory while a human decides.
    create_table :approval_requests, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :workflow_run_id, null: false
      t.string :step_key, null: false
      t.string :decision, null: false, default: "pending" # pending | approved | rejected | expired
      t.jsonb :context, null: false, default: {}          # what the approver is shown
      t.uuid :assignee_team_id
      t.uuid :decided_by_membership_id
      t.text :reason
      t.datetime :requested_at, null: false
      t.datetime :decided_at
      t.datetime :expires_at
      t.timestamps
    end
    add_index :approval_requests, %i[organization_id decision expires_at]
    add_index :approval_requests, %i[organization_id workflow_run_id]
    enable_tenant_rls! :approval_requests

    # The scheduler: a due-time queue in PostgreSQL, NOT the event log. Delays,
    # retries and week-long waits are a different problem from fan-out and
    # replay, and ADR-003 keeps them in different mechanisms on purpose.
    create_table :scheduled_jobs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :kind, null: false                        # resume_run | retry_step | timeout…
      t.uuid :subject_id                                 # run, step, or approval
      t.jsonb :payload, null: false, default: {}
      t.datetime :run_at, null: false
      t.string :status, null: false, default: "pending"  # pending | claimed | done | failed
      t.string :claimed_by
      t.datetime :claimed_until
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.timestamps
    end
    # The claim query: due, unclaimed, within a tenant. Partial because done
    # rows accumulate forever and are never claimed again.
    add_index :scheduled_jobs, %i[organization_id run_at],
              where: "status = 'pending'", name: "index_scheduled_jobs_due"
    enable_tenant_rls! :scheduled_jobs

    # A lease, not a lock. A lock held by a process that was killed mid-step is
    # held forever; a lease expires on the DATABASE's clock and the run is
    # reclaimed. `fence_token` monotonically increases so a resumed zombie
    # worker's writes can be rejected rather than silently accepted.
    create_table :run_leases, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :workflow_run_id, null: false
      t.string :worker_id, null: false
      t.bigint :fence_token, null: false, default: 1
      t.datetime :acquired_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :run_leases, %i[organization_id workflow_run_id], unique: true,
              name: "index_run_leases_one_per_run"
    add_index :run_leases, %i[organization_id expires_at]
    enable_tenant_rls! :run_leases
  end
end
