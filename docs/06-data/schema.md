# Schema Reference

> What each table is for, who owns it, and whether it carries a tenant.
>
> **Status:** ✅ current as of the Phase 4 schema — 55 tables, 2 deliberately absent.

---

## How to read this

**[`db/schema.rb`](../../apps/control-plane/db/schema.rb) is the source of truth for columns, types and
indexes.** This document does not repeat it, because a duplicated column list drifts within a week and nothing
can check it.

What lives here instead is the part `schema.rb` cannot express: **which context owns a table, how it relates to
tenancy, what its one load-bearing constraint is, and how it grows.** That information changes rarely and is
exactly what you need before touching anything.

Ownership is declared machine-readably in
[`config/ownership.yml`](../../apps/control-plane/config/ownership.yml) and enforced by
[boundary-check](../../tools/boundary-check/README.md) — a context that names another's table fails the build
([INV-01](../02-architecture/architecture-constitution.md#inv-01--a-bounded-context-owns-its-tables-exclusively)).

---

## Conventions

Every table follows these unless a row below says otherwise.

| Convention | Detail |
|-----------|--------|
| Primary key | `uuid`, `gen_random_uuid()` (pgcrypto). Sequential integer ids leak volume and collide across placements. |
| Tenant key | `organization_id uuid NOT NULL`, leading an index, governed by an RLS policy |
| Timestamps | `created_at` / `updated_at` on everything |
| Structured columns | `jsonb NOT NULL DEFAULT '{}'` — never nullable, so readers never branch on NULL vs empty |
| Status columns | `string` with the legal values in a comment beside them, not a database enum — a tenant-visible lifecycle changes more often than a type should |
| Money | `*_millicents bigint`. Never a float; per-token costs are far below a cent |
| Cross-context references | Plain `uuid` columns, no foreign key — see [below](#cross-context-references) |

---

## Tenancy classes

Every table is exactly one of these three. The classification is machine-checked in both directions by
`spec/isolation/schema_conformance_spec.rb`.

| Class | Count | Rule |
|-------|-------|------|
| **Tenant-scoped** | 47 | Has `organization_id`; RLS policy keys on it. The default, and the only one that needs no justification. |
| **Tenant root** | 1 | `organizations` — it *is* the tenant, so its policy keys on `id`. Adding a self-referential `organization_id` here is a common and confusing mistake. |
| **Tenant-exempt** | 7 | No tenant at all. Enumerated in `ownership.yml:tenant_exempt` with a per-entry reason; adding one requires an ADR ([INV-13](../02-architecture/architecture-constitution.md#inv-13--every-business-row-is-attributable-to-exactly-one-tenant)). |

The seven exemptions, and why each is one:

| Table | Why it has no tenant |
|-------|---------------------|
| `users` | One human, many organizations. Duplicating accounts per tenant breaks SSO identity; access is mediated by `memberships`, which *is* tenant-scoped |
| `permissions` | The vocabulary of the software, not of a tenant. `workflows.trigger` means the same thing everywhere |
| `event_type_registry` | Same argument, for events |
| `consumer_offsets` | A position in a transport partition. There is no tenant in an offset |
| `tool_catalog_templates` | The catalog of tool *types* the platform ships. A tenant's instance is a `tool_registrations` row |
| `regions` | Deployment topology; identical for every tenant |
| `feature_flags` | Platform rollout state |

---

## Foundation

### Organizations — the tenant root

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `organizations` | The tenant. Name, slug, tier, region, settings | CHECK: `pool` ⇒ no `database_key`, `dedicated` ⇒ required. A dedicated tenant without one is unroutable |
| `memberships` | The user ↔ tenant link. Roles are held *through* this, never globally on a user | Unique `(organization_id, user_id)` |
| `teams`, `team_memberships` | Grouping within a tenant, for approval routing | |
| `org_placements` | Where a tenant's data physically lives ([ADR-009](../11-decisions/ADR-009-multi-tenancy.md)) | |

→ [Organizations](../03-domains/organizations/README.md)

### Identity — principals

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `users` | Humans. **Global** | Unique on `lower(email)` |
| `sessions` | The refresh token *is* this row: digest + `family_id` for reuse detection | Unique `refresh_token_digest` — makes replay detection a lookup, not a scan |
| `service_identities` | Machine principals (`service` / `agent`), FR-106 | Unique `token_digest` |

→ [Identity](../03-domains/identity/README.md) · [ADR-011](../11-decisions/ADR-011-authentication.md)

### Authorization — who may do what

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `permissions` | Global catalog of `resource.action` keys with a risk tier | 44 rows, installed by `PermissionCatalog.install!` |
| `roles` | Tenant-scoped roles, including the four seeded system roles | Unique `(organization_id, key)` |
| `role_permissions` | Which permissions a role grants — expanded explicitly, never a wildcard | Unique `(role_id, permission_key)` |
| `grants` | Binds a role to a membership **or** a service identity | CHECK: exactly one subject, never both, never neither |
| `policies` | ABAC overlay. Refines a decision; can never widen one | |

→ [Authorization](../03-domains/authorization/README.md)

---

## Operational core

### Events — the backbone

Two mechanisms live here and are constantly confused. The **log** carries facts outward; the **store** is the
authoritative history of four aggregates ([ADR-005](../11-decisions/ADR-005-event-sourcing.md)).

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `ingested_events` | Raw inbound webhooks. A 2xx means *stored*, never *processed* (FR-202) | Unique `(organization_id, source, external_id)` — replay protection is the index, not the application's memory |
| `event_store_events` | The event log for event-sourced aggregates | Unique `(organization_id, stream_id, sequence)` — optimistic concurrency. This is why the table cannot be time-partitioned ([ADR-012](../11-decisions/ADR-012-domain-schema.md)) |
| `event_store_snapshots` | A fold cached every N events. **Never authoritative** | Losing every row costs replay time and nothing else |
| `outbox_messages` | Written in the same transaction as the state it describes ([INV-04](../02-architecture/architecture-constitution.md#inv-04--no-dual-writes)) | Partial index on unpublished rows — the relay's working set |
| `inbox_messages` | Consumer-side deduplication | Unique `(organization_id, consumer_group, dedup_key)` — what makes at-least-once harmless |
| `dead_letter_messages` | Unhandleable messages, kept with their error and full payload so replay is possible | |
| `consumer_offsets` | Transport position. Tenant-exempt | Unique `(consumer_group, topic, partition_number)` |
| `event_type_registry` | Event vocabulary and schemas. Tenant-exempt | PK `(key, version)` — versions accumulate; old ones live while stored events use them ([INV-10](../02-architecture/architecture-constitution.md#inv-10--events-are-versioned-and-additively-evolved)) |

→ [Events](../03-domains/events/README.md) · [ADR-003](../11-decisions/ADR-003-event-bus.md)

### Workflows — durable execution

Four properties are in the schema rather than the engine, because an engine can be rewritten and a schema
cannot.

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `workflow_definitions` | Tenant-authored. Data with platform-enforced governance, not deployed code | Unique `(organization_id, key)` |
| `workflow_versions` | Immutable published step graph + checksum | Unique version number per definition |
| `workflow_runs` | Event-sourced aggregate. Pinned to a **version** | Unique idempotency key — the same trigger yields the same run ([INV-12](../02-architecture/architecture-constitution.md#inv-12--a-workflow-run-is-pinned-to-its-definition-version)) |
| `step_executions` | One row per **attempt**. A retry never overwrites the failure it retries | Unique `(run, step_key, attempt)` and unique idempotency key |
| `approval_requests` | Event-sourced. This row *is* the waiting run — nothing is held in memory while a human decides | |
| `scheduled_jobs` | The due-time queue. A different problem from the event log, in a different mechanism | Partial index on pending rows, ordered by `run_at` |
| `run_leases` | Leases that **expire**, not locks that don't survive a crash. Expiry uses the database's clock | Unique per run; `fence_token` lets a zombie worker's writes be rejected |

→ [Workflows](../03-domains/workflows/README.md) · [ADR-006](../11-decisions/ADR-006-workflow-engine.md)

### Agents — governed AI execution

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `agents` | The agent, and the `service_identity_id` that is its own principal | Unique `(organization_id, key)` |
| `agent_versions` | Immutable prompt + model tier + `tool_set` + **`ceilings`** | Ceilings are per version, so tightening a limit is a publish, not a deploy ([INV-22](../02-architecture/architecture-constitution.md#inv-22--every-ai-execution-has-hard-ceilings)) |
| `agent_executions` | Event-sourced. Model, prompt hash, tokens, cost, latency, decision, refusal, `terminated_reason` | `terminated_reason` distinguishes "hit a ceiling" from "finished" — conflating them hides the unbounded-invoice failure |
| `agent_memories` | Model-influenced content, and therefore untrusted on the way back in ([INV-19](../02-architecture/architecture-constitution.md#inv-19--model-output-is-data-never-instruction)) | |
| `tool_registrations` | A tenant's instance of a catalog tool: argument schema, risk tier, approval requirement | Arguments are validated *before* execution, never after |
| `tool_invocations` | Every tool call, **including refused ones** | A denial row is the evidence [INV-20](../02-architecture/architecture-constitution.md#inv-20--no-tool-executes-without-an-authorization-decision) held |

→ [Agents](../03-domains/agents/README.md) · [ADR-007](../11-decisions/ADR-007-ai-runtime.md)

---

## Capabilities

### Integrations — the outside world

Shaped around two assumptions that are always true and usually ignored: the outside world is slow, and the
outside world is down.

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `integrations`, `connections` | A connector and an established connection to one account | |
| `encrypted_credentials` | Ciphertext + **`key_id`** ([INV-18](../02-architecture/architecture-constitution.md#inv-18--secrets-never-leave-the-vault-in-plaintext-form-that-can-be-logged)) | Per-row `key_id` is what makes rotation possible without re-encrypting everything, and crypto-shredding a matter of destroying a key (NFR-602) |
| `webhook_endpoints` | `path_token` (unguessable URL) **and** `secret_digest` (signature) | Both, because a secret URL is not a security control. `path_token` is globally unique: it resolves before a tenant is known |
| `webhook_deliveries` | One row per attempt, both directions | A delivery that succeeded on the fourth try is a different fact from one that succeeded first |
| `endpoint_health` | The circuit breaker, made **durable** | In memory it resets on every deploy — and a breaker that forgets it was open re-hammers a failing dependency |

### Documents / Knowledge

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `knowledge_namespaces` | A retrieval boundary with a classification | "Which documents may this agent retrieve from" is an authorization question; this is the noun it attaches to |
| `documents` | Metadata; bytes live in object storage | `checksum` makes re-ingesting identical bytes a no-op |
| `document_chunks` | Chunked text. Carries its own `organization_id` | Denormalized deliberately: an RLS predicate must not require a join |
| `ingestion_jobs` | Fetch → extract → chunk → embed, with attempts | |

→ [ADR-008](../11-decisions/ADR-008-vector-database.md) · [vector storage](vector-storage.md)

### Notifications

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `notification_channels` | Email / Slack / webhook / in-app. Config only — secrets are credentials | |
| `subscriptions` | Event pattern → channel, optionally per member | |
| `notification_deliveries` | Every send attempt | Unique `dedup_key` — duplicate events are harmless, duplicate 3am pages are how alerting gets muted |

---

## Governance

### Billing / Cost

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `budgets` | Limit, period, scope, and **`hard_stop`** | `hard_stop` is the difference between a budget and a report |
| `reservations` | Two-phase spend: hold before the model call, commit the real cost after | `expires_at` — a worker can die between hold and commit, and a hold never released is a budget that shrinks permanently |
| `cost_rollups` | Derived, rebuildable by construction | Unique per `(dimension, dimension_id, period_start)` |

### Audit

| Table | Holds | Load-bearing constraint |
|-------|-------|------------------------|
| `audit_records` | Append-only, hash-chained: `prev_hash` / `hash` / `chain_position` | Altering a record breaks every link after it, so an auditor verifies the chain without trusting the database's access controls |
| `audit_chains` | Periodic seals over closed ranges | "Nothing was altered since Tuesday" becomes one hash comparison, not a full re-walk |

The chain is **per tenant**: one tenant's evidence must be verifiable and exportable without revealing that
any other tenant exists (NFR-603).

> ⚠️ Append-only is currently a property of the *application* — no mutating path exists — not of the database,
> which would still permit an UPDATE. Database-level enforcement is Phase 13 hardening. Stated here rather than
> described as immutability.

---

## Cross-context references

Columns like `agent_executions.workflow_run_id` and `grants.membership_id` are plain `uuid`s with **no foreign
key**, on purpose.

A `belongs_to` or an FK across a context boundary generates exactly the cross-context query
[INV-01](../02-architecture/architecture-constitution.md#inv-01--a-bounded-context-owns-its-tables-exclusively)
forbids, and it welds the two schemas together permanently — which would remove the extraction option
[ADR-001](../11-decisions/ADR-001-architecture-style.md) was chosen to preserve. **An opaque identifier is the
whole point of a boundary.**

Referential integrity across contexts is therefore the owning context's job, reached through its published
contract. Foreign keys *within* a context are used freely.

---

## How tables grow

| Class | Tables | Bounded by |
|-------|--------|-----------|
| **Per tenant** | organizations, roles, agents, workflow definitions, integrations | Configuration. Thousands, not millions |
| **Per user action** | workflow_runs, agent_executions, documents | Product usage |
| **Per step** | step_executions, tool_invocations, webhook_deliveries | Usage × fan-out — the multiplier to watch |
| **Per event, forever** | event_store_events, audit_records | Retention policy alone. These only ever grow |
| **Self-limiting** | outbox_messages, scheduled_jobs, inbox_messages | The relay and the reaper keeping up. A growing unpublished count is a delivery incident |

The last two rows are where capacity planning actually happens — see
[database architecture](database-architecture.md#where-this-stops-working) and
[partitioning](partitioning.md).

---

## Deliberately absent

Two declared tables were not created. Neither is an oversight; both are recorded as
[TD-010](../technical-debt.md).

| Table | Blocked on | Why it cannot be guessed |
|-------|-----------|--------------------------|
| `chunk_embeddings` | **Q4** — embedding model and dimensionality | A `vector(N)` column *is* that decision: N is fixed at DDL time and changing it rewrites every row. `pgvector` is also unavailable on the development machine |
| `usage_records` | **Q5** — per-event or pre-aggregated per execution | Grain decides row volume at 10⁸ users and whether "which tool call cost that" is answerable. A table cannot be migrated between grains — the detail was either recorded or it was not |

Everything either table depends on exists, so neither blocks other work today. Each gets an ADR before it gets
a migration.

---

## Related

[Database architecture](database-architecture.md) · [ADR-012](../11-decisions/ADR-012-domain-schema.md) ·
[Context map](../02-architecture/context-map.md) ·
[migration-lint](../../tools/migration-lint/README.md) ·
[Technical debt](../technical-debt.md)
