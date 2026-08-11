# Database Architecture

> How PostgreSQL is actually used here, and why the answer is "for almost everything".
>
> **Status:** ✅ describes what exists. Where it describes something planned, it says so inline.
> [ADR-002](../11-decisions/ADR-002-database.md) is the decision; this is the road that decision built.

---

## Understanding This System

**Level 1 — Beginner.** There is one database, and it holds everything that matters. Not "mostly everything" —
domain state, the event history, the outbox, workflow runs, audit records, and (eventually) the search index
and the embeddings. Other stores exist (Redis, object storage, a message broker), but none of them is allowed
to be the only place something lives. If you lose them all, you lose speed, not data.

**Level 2 — Engineer.** One PostgreSQL cluster, three connection identities, three isolation layers, and one
transaction boundary that makes the outbox pattern structural rather than protocol-based
([INV-04](../02-architecture/architecture-constitution.md#inv-04--no-dual-writes)). Every business table
carries `organization_id`, is indexed by it, and is governed by a row-level security policy. Tenants are
either pooled in the shared cluster or placed on a dedicated one, resolved per request
([ADR-009](../11-decisions/ADR-009-multi-tenancy.md)).

**Level 3 — Expert.** The interesting property is not that PostgreSQL can do all of this — it is what becomes
*true* when one transaction can span domain state, its event, and its audit record. Dual writes stop being a
failure mode you mitigate and become one you cannot express. The cost is that write throughput is bounded by a
single primary per placement, and the escape hatch is the dedicated tier rather than a second technology. The
constraints that shape everything else: RLS predicates must not require a join, so tenant keys are
denormalized onto every table; and derived data must be rebuildable, so no projection is ever authoritative.

---

## What is authoritative, and what is not

| Store | Holds | Authoritative? | Losing it entirely means |
|-------|-------|----------------|--------------------------|
| **PostgreSQL** | Domain state, event store, outbox/inbox, workflow runs, agent executions, audit, budgets | **Yes** | Data loss. This is the one that must not be lost. |
| Redis | Cache, rate-limit counters, ephemeral locks, live-push fan-out | No ([INV-08](../02-architecture/architecture-constitution.md#inv-08--redis-is-never-the-source-of-truth-for-durable-business-state)) | Degraded latency. Never a wrong business outcome. |
| Kafka | Event transport | No ([ADR-003](../11-decisions/ADR-003-event-bus.md)) | Delivery delay. The event *store* is the replay source, not the broker. |
| Object storage | Uploaded document bytes | Yes, for blobs | Missing file contents; metadata and chunks survive. |

The rule this table encodes: **a component whose loss changes an answer is authoritative, and there is exactly
one of those.** Redis is not currently installed on the development machine, which is a degradation rather than
a blocker precisely because of INV-08 — see [project state](../00-start-here/project-state.md).

---

## Connection identities

Conflating these is the single easiest way to make tenant isolation silently inert, so they are separate roles
with separate grants ([`db/roles.sql`](../../apps/control-plane/db/roles.sql)).

| Role | Used by | Privileges | RLS applies? |
|------|---------|-----------|--------------|
| `nexus_owner` | Migrations only. Never serves a request. | DDL, owns the tables | Yes — because every table sets `FORCE ROW LEVEL SECURITY` |
| `nexus_app` | Every request-serving and worker process | DML only. No DDL. | Yes |
| `nexus_ro` | Analytics, support tooling | `SELECT` only | Yes |

Both application roles are explicitly `NOSUPERUSER NOBYPASSRLS`. That is not belt-and-braces: a superuser
bypasses RLS unconditionally, and an isolation test executed on a superuser connection **passes while proving
nothing**. That happened on this project's first isolation run — see
[SEC-001](../security/findings.md) — and is why
`Nexus::Database::RowLevelSecurity.assert_enforceable!` refuses to run the suite on a connection that can
bypass policy.

`FORCE` matters for the same reason at the table level: without it, policies do not apply to the table's
*owner*, which is the role that runs migrations and the one most likely to be used for an emergency fix.

### Connection settings

Set for every connection in [`config/database.yml`](../../apps/control-plane/config/database.yml):

| Setting | Value | Why |
|---------|-------|-----|
| `statement_timeout` | 15s | A runaway query is a bounded incident, not an outage |
| `idle_in_transaction_session_timeout` | 30s | Long transactions block vacuum and start the bloat cascade |
| `lock_timeout` | 5s | A blocked migration or write fails fast rather than queueing behind a lock |
| `checkout_timeout` | 5s | Pool saturation surfaces as an error with a correlation ID, not a mystery hang |

---

## Tenant isolation, in three layers

[INV-14](../02-architecture/architecture-constitution.md#inv-14--tenant-isolation-is-enforced-at-three-independent-layers)
requires three layers that fail *independently*. Removing any one must not produce a leak.

| Layer | Mechanism | Fails closed by |
|-------|-----------|-----------------|
| **(a) Database** | RLS policy on every tenant table | `current_setting` returning NULL when unset, so the predicate is never TRUE |
| **(b) Application** | `TenantScopedRecord` default scope + `organization_id` stamping | Raising `UnscopedQuery` rather than returning `all` or `none` |
| **(c) Request** | `Nexus::Tenancy::Context`, Fiber-scoped | Raising `Missing` when read with no tenant established |

The policy predicate, identical on every table:

```sql
USING      (organization_id = NULLIF(current_setting('nexus.organization_id', true), '')::uuid)
WITH CHECK (organization_id = NULLIF(current_setting('nexus.organization_id', true), '')::uuid)
```

Three details, each load-bearing:

- `current_setting(…, true)` returns NULL instead of raising when the variable was never set.
- `NULLIF(…, '')` turns the explicitly-cleared value into NULL too — otherwise `''::uuid` raises a type error
  and the failure looks like a bug rather than a denial.
- `WITH CHECK` applies the predicate to writes. `USING` alone would let one tenant *insert* rows attributed to
  another and merely be unable to read them back.

Either way the comparison yields NULL, which is not TRUE, so no rows match. **Isolation fails closed by
construction, not by anyone remembering to set something.**

`SET LOCAL` is transaction-scoped, so the tenant variable and the work it governs necessarily share one
transaction. That is why every tenant-scoped operation opens one.

### Why tenant keys are denormalized

`document_chunks` carries `organization_id` even though it could reach one through `documents`. This is
deliberate: **an RLS predicate must not require a join.** A policy that joins makes the isolation guarantee
depend on the query planner, on the other table's own policy, and on nobody ever writing a query that defeats
it. One redundant column per table is the cheapest correctness guarantee in the system.

### Verification

Two independent mechanisms, neither of which subsumes the other:

| Mechanism | Reads | Catches |
|-----------|-------|---------|
| [`tools/migration-lint`](../../tools/migration-lint/README.md) | Migration source, at the diff | A new table with no tenant column, no tenant index, or no policy |
| `spec/isolation/schema_conformance_spec.rb` | `pg_class`, `pg_policies`, live | Anything created outside a migration, or altered afterwards |
| `spec/isolation/tenant_isolation_spec.rb` | Behavior, with each layer disabled in turn | A layer that only appears to work because another is covering for it |

---

## The transaction boundary

This is what [ADR-002](../11-decisions/ADR-002-database.md) was chosen for.

```
BEGIN
  SET LOCAL nexus.organization_id = …     -- layer (a) engaged
  INSERT/UPDATE domain state
  INSERT outbox_messages                  -- the event
  INSERT audit_records                    -- the evidence
COMMIT
```

All three commit or none do. There is no window in which the state changed and the event did not, so the
outbox is *structural* — a property of the schema rather than a protocol between components that must both be
working.

The relay then publishes from `outbox_messages` and marks rows published. Delivery is at-least-once
([INV-06](../02-architecture/architecture-constitution.md#inv-06--we-never-claim-exactly-once-delivery)); the
inbox deduplicates on the consuming side.

> **The relay reads per tenant, not globally.** A global scan would need a role that bypasses RLS, and INV-14
> permits no such role. Iterating tenants also gives per-tenant fairness for free: one tenant's backlog cannot
> starve everyone else's.

---

## Indexing conventions

| Convention | Rule |
|-----------|------|
| Tenant first | `organization_id` leads every index on a tenant table. Every query filters by tenant — via RLS if not explicitly — so an index that does not start there is scanned across tenants. Enforced by `migration-lint`. |
| Partial where selective | Working-set indexes are partial: unpublished outbox rows, pending scheduled jobs, undelivered webhooks, denied tool invocations. The excluded majority is never read that way. |
| Unique means invariant | A unique index is a business rule, not a performance hint — event-store stream position, step-execution attempt, inbox dedup key, budget scope. |
| Idempotency keys are indexed | [INV-05](../02-architecture/architecture-constitution.md#inv-05--every-distributed-operation-is-idempotent) is enforced by a unique index, not by a lookup the handler might skip. |

A measured indexing strategy — as opposed to these conventions — needs load to be honest about, and is
[planned for Phase 17](indexing-strategy.md).

---

## Partitioning

**There is none, deliberately.** [ADR-012](../11-decisions/ADR-012-domain-schema.md) refines ADR-002's plan on
two grounds that were measured rather than assumed:

1. **A partition does not inherit its parent's RLS policy.** A query naming a partition directly bypasses the
   policy on the partitioned parent, and `db/roles.sql` grants the application role access to every new table
   by default. Every partition would need its own `ENABLE`/`FORCE`/policy — making the partition-creation job
   a security control, which does not exist until Phase 12.
2. **Time-partitioning is incompatible with the event store.** PostgreSQL requires a unique constraint on a
   partitioned table to include every partitioning column, and the event store's guarantee is
   `UNIQUE (organization_id, stream_id, sequence)`. `event_store_events` is therefore permanently unpartitioned
   by time.

`outbox_messages` and `audit_records` remain candidates, deferred to Phase 17 and gated on that job existing.
Recorded as [TD-009](../technical-debt.md). The full argument and the reversal criteria are in
[ADR-012](../11-decisions/ADR-012-domain-schema.md); the eventual mechanics belong in
[partitioning](partitioning.md).

---

## Placement: pooled and dedicated

[ADR-009](../11-decisions/ADR-009-multi-tenancy.md) runs one codebase over two topologies.

| Tier | Where the tenant's rows live | `organizations.database_key` |
|------|------------------------------|------------------------------|
| `pool` | Shared cluster, isolated by RLS | NULL (enforced by a CHECK constraint) |
| `dedicated` | Its own database | Required (same CHECK) |

`org_placements` records the mapping and `regions` pins residency (NFR-601). The check constraint exists
because a dedicated tenant with no `database_key` is unroutable and a pooled tenant with one is ambiguous —
and the tenant resolver treats that column as authoritative for connection routing.

The dedicated tier is also the write-scaling escape hatch: when a single primary is the bottleneck, the answer
is to move tenants off it, not to adopt a second database technology.

> **Planned, not built.** `infrastructure/database/tenant_resolver.rb` does not exist yet; today every
> connection is the pooled one. The schema supports the split; the routing does not.

---

## Where this stops working

From [ADR-002](../11-decisions/ADR-002-database.md), with the tables most likely to reach each threshold first:

| Scale | Status | Next move |
|-------|--------|-----------|
| 100 M rows/table | Fine with correct indexes | Watch index bloat. `event_store_events`, `audit_records`, `outbox_messages` arrive first |
| 1 B rows/table | Requires partitioning and archival tiering | Time partitions (Phase 17) + cold-storage offload |
| 10 B rows/table | Beyond one primary on the hot path | Shard by tenant via the dedicated tier; offload append-only analytics |

`outbox_messages` is self-limiting if the relay keeps up and published rows are reaped. The event store and
audit records are not — they grow with usage by design, which is why both have retention and sealing paths in
the schema rather than assumed away.

Watch for these before the row counts:

| Signal | Means |
|--------|-------|
| Autovacuum lag on `workflow_runs`, `run_leases` | High-churn update tables bloating; tune per-table autovacuum |
| Growing `outbox_messages` unpublished count | The relay is behind — ingestion is fine, delivery is not |
| Pool checkout timeouts on one role | That role is starving; check per-role metrics before blaming the database |
| Lock waits on migrations | A long-running transaction is holding something; `lock_timeout` fails the migration rather than the app |

---

## Related

[ADR-002](../11-decisions/ADR-002-database.md) · [ADR-009](../11-decisions/ADR-009-multi-tenancy.md) ·
[ADR-012](../11-decisions/ADR-012-domain-schema.md) · [Schema reference](schema.md) ·
[migration-lint](../../tools/migration-lint/README.md) ·
[Constitution](../02-architecture/architecture-constitution.md)
