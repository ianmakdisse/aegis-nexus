# ADR-012 — The domain schema is unpartitioned, and two tables are deliberately missing

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-10 |
| **Deciders** | Platform, Data, Security |
| **Supersedes** | — (refines [ADR-002](ADR-002-database.md) on partitioning) |

---

## Context

Phase 4 creates the core domain model: forty tables across Events, Workflows,
Agents, Integrations, Documents, Notifications, Billing and Audit. Almost all of
it is *implementation* of decisions already made — ADR-003 shapes the backbone,
ADR-005 the event store, ADR-006 the workflow engine, ADR-007 the agent runtime.
Those tables needed no new decision and got none.

Three things did.

**1. ADR-002 committed to time-partitioning the append-only tables.** Line 133:
`RANGE` by time on `events`, `audit_records`, `usage_records`, `outbox_messages`.
That commitment was made before the event store's concurrency model existed and
before anyone had checked how PostgreSQL partitioning interacts with row-level
security. Both turn out to matter.

**2. Two tables have no tenant.** `event_type_registry` and `consumer_offsets`
describe transport and vocabulary, not tenant data. INV-13 requires every
exemption to be enumerated explicitly and to carry an ADR.

**3. Two tables cannot honestly be created yet.** `chunk_embeddings` and
`usage_records` each have a shape that an unresolved question decides — Q4
(embedding model and dimensionality) and Q5 (usage grain). Writing the migration
would answer both, silently, in DDL.

## Requirements driving this decision

| ID | Requirement |
|----|-------------|
| [INV-13](../02-architecture/architecture-constitution.md#inv-13--every-business-row-is-attributable-to-exactly-one-tenant) | Every business row attributable to exactly one tenant; exemptions enumerated |
| [INV-14](../02-architecture/architecture-constitution.md#inv-14--tenant-isolation-is-enforced-at-three-independent-layers) | Three independent isolation layers, each failing independently |
| [INV-11](../02-architecture/architecture-constitution.md#inv-11--schema-changes-are-safe-for-rolling-deployment) | Schema changes safe for rolling deployment |
| [ADR-005](ADR-005-event-sourcing.md) | Optimistic concurrency on the event store |
| [NFR-603](../01-product/requirements.md#nfr-603) | Exportable, verifiable audit evidence per tenant |

## Considered alternatives

### A. Partition now, as ADR-002 planned

Create `event_store_events`, `outbox_messages` and `audit_records` as
`PARTITION BY RANGE` from the start.

**Advantages** — Genuinely the cheapest moment to do it. These tables are empty;
converting a populated table to a partitioned one later means creating a new
table and moving every row, which at the volumes ADR-002 anticipates is a
maintenance window nobody wants to schedule. Doing it now also means the
partition-maintenance job is written while the tables are harmless rather than
under pressure.

**Disadvantages** — Two, found by probing PostgreSQL 14 rather than by reasoning:

*It breaks the event store's concurrency control.* PostgreSQL requires a unique
constraint on a partitioned table to include every partitioning column:

```
ERROR: unique constraint on partitioned table must include all partitioning columns
```

The event store's guarantee is `UNIQUE (organization_id, stream_id, sequence)` —
two writers appending sequence N to one stream must collide. Adding `occurred_at`
to that index permits two events at the same sequence with different timestamps,
which is precisely the anomaly the constraint exists to prevent. ADR-005's
optimistic concurrency would become advisory.

*It silently weakens tenant isolation.* A policy on the partitioned parent is
**not** applied when a query names a partition directly. Measured on this
schema's own configuration:

| Query | Rows visible to a non-owning tenant |
|-------|-------------------------------------|
| `SELECT … FROM _probe` (parent) | 0 ✅ |
| `SELECT … FROM _probe_default` (partition) | **1** ❌ |

And `db/roles.sql` sets `ALTER DEFAULT PRIVILEGES … GRANT … ON TABLES TO
nexus_app`, so every partition is automatically readable by the application
role as it is created. Isolation would therefore depend on nobody ever naming a
partition — in a maintenance script, a diagnostic query, or a bug. Each partition
needs its own `ENABLE` + `FORCE` + policy, which means the partition-creation job
becomes a security control. That job does not exist until Phase 12.

Partitioning also forces `schema_format = :sql`, because `schema.rb` cannot
express a partitioned table.

### B. Partition only the tables where it is safe, now

`outbox_messages` and `audit_records` have no cross-partition uniqueness, so
alternative A's first objection does not apply to them.

**Advantages** — Captures most of the future benefit at the cheapest moment,
and confines the complexity to two tables.

**Disadvantages** — The isolation objection still applies in full, and it is the
serious one. It would introduce a rule ("every new partition needs a policy")
enforced by nothing, in the phase immediately before the system starts holding
real tenant data. It also splits the schema into two mental models for no
present benefit, since both tables are empty.

### C. *(chosen)* Unpartitioned now; partition when the maintenance job exists

Create all forty tables as ordinary tables. Defer partitioning to Phase 17
(performance and capacity), where the scheduler exists and a partition-creation
job can own both the ranges and the policies.

**Advantages** — The isolation model stays uniform and fully verified: every
tenant table has `ENABLE` + `FORCE` + a policy, and a new conformance spec
asserts that from the live catalog rather than from a list. `schema.rb` remains
readable. No table acquires a rule that only a future job will enforce. The
event store keeps a real uniqueness guarantee.

**Disadvantages** — Genuine and worth stating plainly: converting these tables
later is more expensive than creating them partitioned today, and the cost grows
with every row. We are choosing a known future migration over a present
correctness risk, and if that migration is neglected the cost lands on whoever
inherits it. This is the alternative's strongest argument and it does not go
away.

## Decision

The Phase 4 domain schema is **unpartitioned**. `event_store_events` is
permanently unpartitioned by time, because time-range partitioning is
incompatible with the per-stream sequence uniqueness ADR-005 depends on; this
refines ADR-002's plan rather than deferring it. `outbox_messages` and
`audit_records` remain candidates for time partitioning, deferred to Phase 17,
gated on a partition-maintenance job that applies row-level security to every
partition it creates and a test proving a directly-queried partition denies
cross-tenant reads.

`event_type_registry` and `consumer_offsets` are added to
`ownership.yml:tenant_exempt` — the first describes the software's event
vocabulary, exactly as `permissions` describes its authorization vocabulary; the
second is a position in a transport partition, and there is no tenant in an
offset.

`chunk_embeddings` and `usage_records` are **not created**. Q4 and Q5 are
answered by an ADR when they start blocking, not by a migration.

## Why

The asymmetry is between a cost that is visible and a failure that is not.

Partitioning later is expensive, and we will know exactly how expensive — it is a
scheduled migration with a measurable row count. A partition without a policy is
a cross-tenant read that no test covers, discovered by an auditor or an attacker.
The first is a bill; the second is the failure this entire architecture exists to
prevent.

Deferring the two blocked tables follows the same logic. A wrong `vector(N)` or a
wrong usage grain is not a bug to fix later — it is data never recorded, or a
column rewrite over the largest table in the system.

## Consequences

**What becomes true:**

- Every tenant table in the database has RLS enabled, forced, and policied — and
  `spec/isolation/schema_conformance_spec.rb` asserts it from `pg_class` and
  `pg_policies`, so the guarantee scales with the schema rather than with the
  diligence of the next migration author.
- The INV-13 exemption list is machine-checked in two directions: a table with no
  tenant must be declared, and a declared exemption that has grown an
  `organization_id` is a failure.
- `schema.rb` stays the schema format; no `structure.sql` migration is needed.
- Retrieval is one column short of complete, and metering one table short.

**Obligations this creates:**

| Obligation | When |
|-----------|------|
| Partition-maintenance job that applies RLS to every partition it creates, plus a test that a directly-queried partition denies cross-tenant reads | Phase 17, before any partitioning |
| Resolve Q4 (embedding model + dimensionality) in an ADR, then create `chunk_embeddings` | Phase 10 |
| Resolve Q5 (usage grain) in an ADR, then create `usage_records` | Phase 9 |
| Database-level prevention of UPDATE/DELETE on `audit_records` | Phase 13 |
| `pgvector` available in every environment | Phase 10 |

## Failure modes

| Failure mode | Detection | Impact | Mitigation |
|--------------|-----------|--------|------------|
| A new table ships with no RLS policy | `migration-lint` at the diff; conformance spec against the catalog | Cross-tenant reads on that table | Two independent checks, one static and one live |
| A future partition is created without a policy | No detection today — this is why partitioning is deferred | Cross-tenant reads via the partition | Do not partition until the job and its test exist |
| Tables grow large enough that partitioning becomes painful | Row-count alert per table | An expensive migration window | The rollup and retention paths exist; Phase 17 owns the trigger |
| `audit_records` is altered in place | Hash-chain verification (`audit_chains`) | Audit evidence loses value | Chain verification is a published contract, not a background job |
| An exemption becomes stale | Conformance spec's stale-exemption example | A documented reason not to look at a real tenant table | Asserted in both directions |

## Operational impact

**Adds:** nothing this phase — no partitions to pre-create, no `structure.sql`
in the deploy path, no new maintenance job.

**Removes:** the class of incident where a partition boundary is missed and
inserts start failing on a date. There are no partitions, so there is no date.

**On-call must know:** the audit chain is per tenant, so verifying or exporting
one tenant's evidence never touches another's.

## Cost impact

Marginal storage cost is unchanged; forty empty tables cost nothing. The deferred
cost is the eventual partitioning migration on `outbox_messages` and
`audit_records`, which grows with retained rows — the reason both have retention
paths designed in (`published_at`, `audit_chains` seals) rather than assumed.

## Security impact

**Better:** isolation is uniform and verified from the live catalog rather than
asserted per table. The INV-13 exemption list is now enumerated and checked,
which INV-13 required from the start and which nothing enforced until this phase.
Credentials are stored with a per-row `key_id`, which is what makes rotation and
crypto-shredding possible (NFR-602).

**Worse:** forty tables is a much larger surface than fifteen, and every one of
them now depends on `enable_tenant_rls!` being called. The conformance spec is
the compensating control, and it is only as good as its own non-vacuity — which
is why it asserts a minimum table count and is mutation-tested by removing RLS
from two tables and confirming it fails.

**Unresolved:** `audit_records` is append-only by convention, not by grant. The
application has no mutating path, but the database would permit one. Phase 13.

## Scalability impact

Where it stops working: ADR-002 puts the comfortable ceiling around 100 M
rows/table with correct indexes, and `event_store_events`, `outbox_messages` and
`audit_records` are the three that will reach it first. `outbox_messages` is
self-limiting if the relay keeps up and rows are reaped after publication; the
other two are not.

The next move is stated above rather than left to be discovered: partition the
two that can be partitioned, and for the event store, shard by tenant via the
dedicated tier ([ADR-009](ADR-009-multi-tenancy.md)) — which is the escape hatch
that decision was chosen for.

## Reversal criteria

| Trigger | Move |
|---------|------|
| Any of the three high-volume tables passes 50 M rows | Bring Phase 17 forward; build the partition job and its RLS test first |
| A partition-maintenance job exists with a proven per-partition RLS test | Partition `outbox_messages` and `audit_records`; the event store stays unpartitioned regardless |
| PostgreSQL removes the requirement that unique constraints include partitioning columns | Re-examine the event store — this ADR's first objection would no longer hold |
| Q4 or Q5 is answered | Create the corresponding table in its own migration, with its own ADR |

## Related decisions

[ADR-002](ADR-002-database.md) — refined here on partitioning ·
[ADR-005](ADR-005-event-sourcing.md) — the concurrency guarantee that rules out
time-partitioning the event store · [ADR-009](ADR-009-multi-tenancy.md) — the
sharding escape hatch · [ADR-008](ADR-008-vector-database.md) — blocked on Q4

## Related code

- `apps/control-plane/db/migrate/20260810000005_create_event_backbone.rb`
- `apps/control-plane/db/migrate/20260810000006_create_workflow_engine.rb`
- `apps/control-plane/db/migrate/20260810000007_create_agent_runtime.rb`
- `apps/control-plane/db/migrate/20260810000010_create_billing_and_audit.rb`
- `apps/control-plane/spec/isolation/schema_conformance_spec.rb`
- `apps/control-plane/lib/nexus/migration/tenancy.rb`
- `tools/migration-lint/`

## Related diagrams

[Context map](../02-architecture/context-map.md) · [Data flow](../02-architecture/data-flow.md)
