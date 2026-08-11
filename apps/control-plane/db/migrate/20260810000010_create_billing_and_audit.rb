# frozen_string_literal: true

# Phase 4 — the Billing/Cost and Audit contexts.
#
# DELIBERATELY MISSING: `usage_records`.
#
# Unresolved question Q5 — per-event or pre-aggregated per execution — decides
# this table's grain, its row volume at 10⁸ users, and whether cost attribution
# can answer "which tool call cost that". Grain is not something a table can be
# migrated between cheaply: it is the difference between having the detail and
# never having recorded it. Q5 is marked as blocking Phase 9, and this is the
# migration that would have silently answered it. See ADR-012.
#
# `reservations` and `cost_rollups` do not depend on that grain, so budget
# enforcement can be built before Q5 is settled.
class CreateBillingAndAudit < ActiveRecord::Migration[7.1]
  include Nexus::Migration::Tenancy

  def change
    # ---- Billing / Cost ----------------------------------------------------

    # `hard_stop` is the difference between a budget and a report. A soft budget
    # that only notifies is what an unbounded agent spends through overnight
    # (INV-22).
    create_table :budgets, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :scope, null: false, default: "organization"  # organization | agent | workflow
      t.uuid :scope_id
      t.string :period, null: false, default: "monthly"      # daily | monthly | total
      t.bigint :limit_millicents, null: false
      t.boolean :hard_stop, null: false, default: true
      t.datetime :starts_at, null: false
      t.datetime :ends_at
      t.timestamps
    end
    add_index :budgets, %i[organization_id scope scope_id], unique: true,
              name: "index_budgets_scope"
    enable_tenant_rls! :budgets

    # Two-phase spend. An agent execution HOLDS an amount before calling a
    # model and commits the real cost afterwards, so concurrent executions
    # cannot each pass a budget check and collectively blow through it.
    #
    # `expires_at` exists because a worker can die between hold and commit, and
    # a hold that is never released is a budget that shrinks permanently.
    create_table :reservations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :budget_id, null: false
      t.uuid :agent_execution_id
      t.bigint :amount_millicents, null: false
      t.string :state, null: false, default: "held"      # held | committed | released | expired
      t.datetime :expires_at, null: false
      t.datetime :settled_at
      t.timestamps
    end
    add_index :reservations, %i[organization_id budget_id state],
              name: "index_reservations_outstanding"
    add_index :reservations, %i[organization_id expires_at],
              where: "state = 'held'", name: "index_reservations_expiring"
    enable_tenant_rls! :reservations

    # Derived data: rebuildable from usage by construction, which is what makes
    # a projection failure a delay rather than a loss.
    create_table :cost_rollups, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :dimension, null: false                   # agent | workflow | model | tool
      t.uuid :dimension_id
      t.datetime :period_start, null: false
      t.datetime :period_end, null: false
      t.bigint :tokens_in, null: false, default: 0
      t.bigint :tokens_out, null: false, default: 0
      t.bigint :cost_millicents, null: false, default: 0
      t.integer :execution_count, null: false, default: 0
      t.timestamps
    end
    add_index :cost_rollups, %i[organization_id dimension dimension_id period_start],
              unique: true, name: "index_cost_rollups_period"
    enable_tenant_rls! :cost_rollups

    # ---- Audit -------------------------------------------------------------

    # Append-only and hash-chained. `prev_hash`/`hash` make tampering
    # detectable: altering a record breaks every link after it, so an auditor
    # can verify the chain without trusting the database's access controls.
    # That is what turns "we have logs" into evidence (NFR-603).
    #
    # No UPDATE or DELETE path exists in the application for this table. The
    # database-level enforcement of that is Phase 13 hardening; the absence of
    # a mutating contract is the enforcement today, which is weaker and is
    # recorded as such rather than described as immutability.
    create_table :audit_records, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :actor_kind, null: false                  # user | service | agent | system
      t.uuid :actor_id
      t.string :action, null: false                      # the permission key that was exercised
      t.string :resource_type, null: false
      t.uuid :resource_id
      t.string :outcome, null: false                     # allowed | denied | failed
      t.jsonb :metadata, null: false, default: {}
      t.string :trace_id
      t.string :correlation_id
      t.bigint :chain_position, null: false
      t.string :prev_hash
      t.string :hash, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    # The chain is per tenant: one tenant's records must be verifiable, and
    # exportable, without revealing that any other tenant's records exist
    # (NFR-603).
    add_index :audit_records, %i[organization_id chain_position], unique: true,
              name: "index_audit_records_chain"
    add_index :audit_records, %i[organization_id occurred_at]
    add_index :audit_records, %i[organization_id actor_kind actor_id]
    add_index :audit_records, %i[organization_id resource_type resource_id]
    enable_tenant_rls! :audit_records

    # A periodic seal over a closed range of the chain. Verifying "nothing was
    # altered since Tuesday" is then one hash comparison rather than a full
    # re-walk of the tenant's history.
    create_table :audit_chains, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.bigint :start_position, null: false
      t.bigint :end_position, null: false
      t.string :head_hash, null: false
      t.integer :record_count, null: false, default: 0
      t.datetime :period_start, null: false
      t.datetime :period_end, null: false
      t.datetime :sealed_at, null: false
      t.timestamps
    end
    add_index :audit_chains, %i[organization_id end_position], unique: true,
              name: "index_audit_chains_seal"
    enable_tenant_rls! :audit_chains
  end
end
