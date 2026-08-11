# frozen_string_literal: true

# Phase 4 — the Agents context (ADR-007).
#
# We own the agent loop rather than delegating it, because permission checks,
# budget ceilings, argument validation, audit and suspension-for-approval all
# have to happen BETWEEN every model turn and every tool call. These tables are
# the control points made durable.
#
# Three constitutional facts are structural here:
#   INV-19  model output is data, never instruction — nothing a model produces
#           is stored anywhere that is read back as policy
#   INV-20  no tool executes without an authorization decision — hence
#           `authorized` and `denial_reason` on every invocation
#   INV-22  every execution has hard ceilings — hence `terminated_reason`
class CreateAgentRuntime < ActiveRecord::Migration[7.1]
  include Nexus::Migration::Tenancy

  def change
    create_table :agents, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: "draft"    # draft | active | disabled
      t.uuid :service_identity_id                        # the agent's own principal (FR-106)
      t.uuid :created_by_membership_id
      t.timestamps
    end
    add_index :agents, %i[organization_id key], unique: true
    enable_tenant_rls! :agents

    # Immutable once published, for the same reason workflow versions are: an
    # execution records which version ran, and editing history is not a feature.
    create_table :agent_versions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :agent_id, null: false
      t.integer :version, null: false
      t.text :system_prompt, null: false
      t.string :prompt_checksum, null: false
      t.string :model_tier, null: false, default: "standard"  # ADR-007 routing tiers
      t.jsonb :tool_set, null: false, default: []             # tool_registration keys
      # INV-22 ceilings: tokens, cost, wall-clock, tool calls, recursion depth.
      # Stored per version so tightening a limit is a publish, not a deploy.
      t.jsonb :ceilings, null: false, default: {}
      t.datetime :published_at
      t.timestamps
    end
    add_index :agent_versions, %i[organization_id agent_id version], unique: true,
              name: "index_agent_versions_number"
    enable_tenant_rls! :agent_versions

    # Event-sourced aggregate (ADR-005). This is the row that answers "what did
    # the agent do and why" (INV-21, FR-405) — audit writes here are not
    # optional and not best-effort.
    create_table :agent_executions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :agent_version_id, null: false
      t.uuid :workflow_run_id                            # set when a step invoked it
      # Who this agent acts FOR. INV-16: effective permissions are the
      # intersection with this principal's, so the column is not decoration.
      t.uuid :invoker_membership_id
      t.uuid :invoker_service_identity_id
      t.string :status, null: false, default: "running"
      t.string :model                                    # exact model id, not a family
      t.string :model_version
      t.string :prompt_hash, null: false                 # reproducibility without storing the prompt
      t.integer :tokens_in, null: false, default: 0
      t.integer :tokens_out, null: false, default: 0
      t.integer :cached_tokens, null: false, default: 0  # the usual cause of a cost spike
      t.integer :cost_millicents, null: false, default: 0
      t.integer :latency_ms
      t.integer :tool_call_count, null: false, default: 0
      t.integer :recursion_depth, null: false, default: 0
      t.jsonb :decision                                  # the agent's output, as DATA (INV-19)
      t.decimal :confidence, precision: 5, scale: 4
      t.string :refusal_category
      # Set when a ceiling stopped this execution. An agent that hit a limit
      # terminated deterministically; one that finished did not. Conflating the
      # two hides the unbounded-invoice failure mode (INV-22).
      t.string :terminated_reason
      t.string :trace_id
      t.string :correlation_id
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end
    add_index :agent_executions, %i[organization_id started_at]
    add_index :agent_executions, %i[organization_id agent_version_id]
    add_index :agent_executions, %i[organization_id workflow_run_id]
    add_index :agent_executions, %i[organization_id terminated_reason],
              where: "terminated_reason IS NOT NULL", name: "index_agent_executions_terminated"
    enable_tenant_rls! :agent_executions

    create_table :agent_memories, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :agent_id, null: false
      t.string :scope, null: false, default: "agent"     # agent | run | principal
      t.uuid :scope_id
      t.string :key, null: false
      # Memory is model-influenced content and therefore untrusted input on the
      # way back in (INV-19). It is stored as data and re-enters a prompt as
      # quoted content, never as instruction.
      t.jsonb :content, null: false, default: {}
      t.datetime :expires_at
      t.timestamps
    end
    add_index :agent_memories, %i[organization_id agent_id scope scope_id key],
              unique: true, name: "index_agent_memories_key"
    add_index :agent_memories, %i[organization_id expires_at]
    enable_tenant_rls! :agent_memories

    # A tenant's instance of a catalog tool: which connector, which arguments
    # are legal, how risky, and whether a human must approve it.
    create_table :tool_registrations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.string :key, null: false
      t.string :template_key                             # → tool_catalog_templates
      t.string :name, null: false
      # Validated before execution, never after (INV-20). The model proposes
      # arguments; this schema is what decides whether they are even legal.
      t.jsonb :argument_schema, null: false, default: {}
      t.string :risk_tier, null: false, default: "LOW"
      t.boolean :requires_approval, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.uuid :connection_id                              # → Integrations, by id only
      t.timestamps
    end
    add_index :tool_registrations, %i[organization_id key], unique: true
    enable_tenant_rls! :tool_registrations

    # Every tool call, including the ones that were refused. A denial is the
    # most important row in this table: it is the evidence that INV-20 held.
    create_table :tool_invocations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :organization_id, null: false
      t.uuid :agent_execution_id, null: false
      t.uuid :tool_registration_id, null: false
      t.jsonb :arguments, null: false, default: {}
      t.jsonb :result
      t.boolean :authorized, null: false, default: false
      t.string :denial_reason                            # from Authorization's decision
      t.string :status, null: false, default: "proposed" # proposed | authorized | executed | denied | failed
      t.string :idempotency_key, null: false
      t.integer :latency_ms
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end
    add_index :tool_invocations, %i[organization_id agent_execution_id]
    add_index :tool_invocations, %i[organization_id idempotency_key], unique: true,
              name: "index_tool_invocations_idempotency"
    add_index :tool_invocations, %i[organization_id authorized],
              where: "authorized = false", name: "index_tool_invocations_denials"
    enable_tenant_rls! :tool_invocations

    # Platform-global (INV-13 exemption, already declared): the catalog of tool
    # TYPES the platform ships. A tenant's instance of one is a
    # tool_registration, which is tenant-scoped.
    create_table :tool_catalog_templates, id: false do |t|
      t.string :key, primary_key: true, null: false
      t.string :name, null: false
      t.string :category, null: false
      t.jsonb :argument_schema, null: false, default: {}
      t.string :default_risk_tier, null: false, default: "LOW"
      t.boolean :requires_approval_by_default, null: false, default: false
      t.timestamps
    end
  end
end
