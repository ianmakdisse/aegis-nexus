# Codebase Navigation (Level 5)

> Subsystem → entry point → public API → internals → tables → events → jobs → tests → metrics.
>
> Paths marked ⬜ are designed but not yet implemented — check [project-state.md](project-state.md).
> `docs-lint` warns on every path here that does not exist, so this table cannot silently drift.

---

## Repository shape

```
aegis-nexus/
├── docs/                              knowledge base
├── apps/control-plane/
│   ├── app/                           DELIVERY — controllers, channels, serializers
│   ├── domains/<context>/             BUSINESS — Nexus::<Context>
│   │   ├── *.rb                       public contract
│   │   └── internal/                  private (boundary-check enforced)
│   ├── infrastructure/                MECHANISMS — Nexus::*
│   ├── config/
│   │   ├── ownership.yml              context boundaries (machine-readable)
│   │   ├── roles.yml                  process roles
│   │   └── application.rb             autoloading, role, transport
│   ├── db/{migrate,policies}/         schema + RLS policies
│   ├── lib/nexus.rb                   root namespace + why it exists
│   └── bin/role-entrypoint            role dispatcher
├── infra/{docker,k8s,helm,terraform}/
└── tools/{docs-lint,boundary-check}/
```

**The one rule that explains the layout:** `app/` is how requests arrive; `domains/` is what the business
means; `infrastructure/` is how distributed systems work. Dependencies point downward only.

---

## Finding things fast

| I'm looking for… | Look in |
|------------------|---------|
| A context's public API | `domains/<ctx>/*.rb` (top level only) |
| What a context may expose | `config/ownership.yml` → `contexts.<ctx>.public` |
| Which context owns a table | `config/ownership.yml` → grep the table name |
| Why a cross-context call is allowed | `config/ownership.yml` → `sync_allowed` (each has a `why`) |
| What a role boots | `config/roles.yml` + `bin/role-entrypoint` |
| RLS policies | `db/policies/` |
| Where an event is defined | `domains/<ctx>/internal/events/` |
| Where an event is consumed | `grep -r "subscribe_to.*<event.type>" domains/` |

---

## Subsystem maps

### Events — `domains/events/` + `infrastructure/events/`

| | |
|---|---|
| **Entry** | `Nexus::Events::Publisher` (publish) · `Nexus::Events::Consumer` (handle) |
| **Public** | `Publisher`, `Consumer`, `Replay`, `EventType`, `Envelope` |
| **Internals** ⬜ | `infrastructure/events/outbox_relay.rb`, `.../consumer.rb`, `.../transport/{kafka,postgres_log}.rb` |
| **Tables** | `ingested_events`, `event_store_events`, `outbox_messages`, `inbox_messages`, `dead_letter_messages`, `consumer_offsets` |
| **Roles** | `ingest`, `relay`, `consumer` |
| **Metrics** | `outbox_oldest_age_seconds`, `consumer_lag_seconds`, `inbox_duplicate_total`, `dlq_depth` |
| **Key rule** | `Publisher` raises outside a transaction (INV-04); `Consumer` refuses a handler with no dedup key (INV-05) |
| **Docs** | [ADR-003](../11-decisions/ADR-003-event-bus.md) · [event flow](../02-architecture/event-flow.md) |

### Workflows — `domains/workflows/` ⬜

| | |
|---|---|
| **Entry** | `Nexus::Workflows::Trigger` |
| **Public** | `Trigger`, `Run`, `Definition`, `Approve`, `Cancel` |
| **Internals** ⬜ | `internal/engine/` (interpreter, leases, scheduler), `internal/steps/` (one class per step type), `internal/aggregates/` |
| **Tables** | `workflow_definitions`, `workflow_versions`, `workflow_runs`, `step_executions`, `approval_requests`, `scheduled_jobs`, `run_leases` |
| **Roles** | `worker:default`, `scheduler` |
| **Metrics** | `stuck_runs`, `lease_reclaim_total`, `step_attempt_total`, `run_duration_seconds` |
| **Key rule** | Runs pin to a version (INV-12); state is durable before a step is attempted (INV-07) |
| **Docs** | [ADR-006](../11-decisions/ADR-006-workflow-engine.md) · [runtime](../03-domains/workflows/runtime.md) |

### Agents — `domains/agents/` ⬜

| | |
|---|---|
| **Entry** | `Nexus::Agents::Invoke` |
| **Public** | `Invoke`, `Execution`, `Agent`, `ToolRegistry` |
| **Internals** ⬜ | `internal/runtime/` (loop, governor), `internal/providers/` (port + adapters), `internal/routing/`, `internal/prompt/assembler.rb`, `internal/tools/`, `internal/memory/` |
| **Tables** | `agents`, `agent_versions`, `agent_executions`, `agent_memories`, `tool_registrations`, `tool_invocations` |
| **Roles** | `worker:agents` |
| **Metrics** | `ai_latency_p99`, `ai_refusal_total`, `tool_denial_total`, `agent_ceiling_hits`, `cache_read_input_tokens` |
| **Key rule** | Model output is data (INV-19); no tool without authorization (INV-20); ceilings enforced by the runtime (INV-22) |
| **Docs** | [ADR-007](../11-decisions/ADR-007-ai-runtime.md) · [agent runtime](../05-ai/agent-runtime.md) |

### Organizations & tenancy — `domains/organizations/` + `infrastructure/tenancy/`

| | |
|---|---|
| **Entry** | `Nexus::Organizations::Tenant`, `Nexus::Tenancy::Context` |
| **Internals** ⬜ | `infrastructure/database/tenant_resolver.rb`, `db/policies/` |
| **Tables** | `organizations`, `memberships`, `teams`, `org_placements` |
| **Key rule** | Missing tenant context raises (INV-14 layer c); three layers tested independently |
| **Docs** | [ADR-009](../11-decisions/ADR-009-multi-tenancy.md) · [tenant isolation](../08-security/tenant-isolation.md) |

### Authorization — `domains/authorization/`

| | |
|---|---|
| **Entry** | `Nexus::Authorization::Authorize.call!` |
| **Tables** | `roles`, `permissions`, `role_permissions`, `grants`, `policies` |
| **Key rule** | Deny by default; **never** reads a projection or cache ([ADR-010](../11-decisions/ADR-010-consistency-model.md) Rule 1); delegation narrows only (INV-16) |

### Documents & knowledge — `domains/documents/` ⬜

| | |
|---|---|
| **Entry** | `Nexus::Documents::Ingest`, `Nexus::Documents::Retrieve` |
| **Internals** ⬜ | `internal/vector_store/`, `internal/retrieval/`, `internal/embedding/`, `internal/chunking/` |
| **Tables** | `documents`, `document_chunks`, `chunk_embeddings`, `ingestion_jobs`, `knowledge_namespaces` |
| **Roles** | `worker:documents` |
| **Key rule** | `tenant:` is a required argument on every store call (FR-503); retrieved text is untrusted |
| **Docs** | [ADR-008](../11-decisions/ADR-008-vector-database.md) · [RAG](../05-ai/rag.md) |

### Billing — `domains/billing/` ⬜

| | |
|---|---|
| **Entry** | `Nexus::Billing::Meter`, `Nexus::Billing::CheckBudget` |
| **Tables** | `budgets`, `usage_records`, `cost_rollups`, `reservations` |
| **Key rule** | Enforcement reads authoritative rows + reservations, **never** rollups |

### Audit — `domains/audit/` ⬜

| | |
|---|---|
| **Entry** | `Nexus::Audit::Record`, `Nexus::Audit::Verify` |
| **Tables** | `audit_records`, `audit_chains` |
| **Key rule** | Written in the same transaction as the audited action — never async |

---

## Tracing a symptom to code

| Symptom | Start here | Then |
|---------|-----------|------|
| Event never processed | `outbox_messages` (age), then `consumer_offsets`, then `dead_letter_messages` | Three different failures — published? delivered? handled? |
| Workflow stuck | `workflow_runs.state`, `run_leases.expires_at` | Sleeping on purpose, or a lease not being reclaimed? |
| Agent misbehaved | `agent_executions` → prompt hash, tool calls, denials | `internal/runtime/` |
| Cost spike | `usage_records` → tier, effort, cache tokens | `internal/routing/` |
| Cross-tenant data | **Security incident** | `infrastructure/tenancy/`, `db/policies/` |
| Stale dashboard | Projection lag SLI, then reconciliation | `infrastructure/projections/` |
