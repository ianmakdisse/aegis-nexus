# ADR-002 — Primary Datastore: PostgreSQL, with Explicit Limits

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-09 |
| **Deciders** | Database Architect, Principal Architect, SRE |
| **Supersedes** | — |

---

## Context

Aegis Nexus stores several fundamentally different shapes of data:

| Shape | Example | Access pattern | Volume driver |
|-------|---------|----------------|---------------|
| Relational config | orgs, users, roles, agents, tools | Small, read-heavy, joined | tenants |
| Append-only log | event store, audit, outbox | Write-once, sequential, range-scanned by key | events/sec |
| Durable execution state | workflow runs, step executions | Read-modify-write under contention, leased | concurrent runs |
| Derived read models | projections, dashboards | Read-heavy, rebuildable | queries/sec |
| Metering | usage records | Very high insert rate, aggregated | AI calls |
| Vectors | document chunk embeddings | ANN search with metadata filters | documents |
| Full-text | documents, events, audit | BM25 + filters | documents |

A naive reading suggests six datastores. Each additional datastore adds: a failure mode, a backup and
restore procedure, a security review, a scaling model, an on-call learning curve, and — most expensively —
a **consistency boundary** where none existed before.

The decisive constraint is INV-04 (no dual writes). The transactional outbox requires that domain state and
the outbox row commit atomically. Every store that holds *authoritative* state and is not the same store as
the outbox re-creates the dual-write problem we are architecturally committed to eliminating.

## Requirements driving this decision

FR-101/102 (row-level tenant isolation) · FR-204 (transactional outbox) · FR-208 (replay) ·
FR-301 (durable execution) · FR-801 (immutable audit) · NFR-203/204 (RPO < 5 min, RTO < 15 min) ·
NFR-404 (10⁹ rows viable in the largest tables).

## Considered alternatives

### A. PostgreSQL for everything authoritative *(chosen)*
Relational + JSONB + append-only tables + partitioning + `pgvector` for embeddings + `tsvector`/GIN for
initial full-text, with purpose-built stores adopted only where measurement proves PostgreSQL insufficient.

**Advantages**
- One transaction boundary. The outbox, the event store, and the domain state commit together — INV-04 is
  satisfied structurally rather than by protocol.
- Row-Level Security gives tenant isolation *in the database*, which is layer (a) of INV-14 and cannot be
  bypassed by an application bug.
- Mature PITR, logical + physical replication, and well-understood failover — directly serving NFR-203/204.
- Declarative partitioning handles the high-volume append-only tables.
- One backup story, one restore rehearsal, one security posture.
- Operationally boring, which is the highest praise available for a datastore.

**Disadvantages**
- Connection scaling is genuinely poor (one backend process per connection) — mandatory pooler.
- Vacuum/bloat management on high-churn tables (workflow runs, leases) requires active attention.
- `pgvector` ANN quality/latency lags dedicated vector databases at large index sizes ([ADR-008](ADR-008-vector-database.md)).
- Postgres full-text search is adequate, not excellent: no native BM25 tuning, weaker analyzers, no faceting.
- Single-writer per primary; write scaling requires partitioning by tenant, not just bigger machines.

### B. Polyglot persistence from day one
Postgres (relational) + Cassandra/ScyllaDB (event store) + Elasticsearch (search) + Qdrant (vectors) +
ClickHouse (metering/analytics).

**Advantages**
- Each store optimal for its workload; each scales on its own axis.
- Metering aggregation in ClickHouse would be dramatically faster than in Postgres at high cardinality.

**Disadvantages**
- The outbox must span stores → distributed transactions or per-store outboxes → the exact class of bug this
  architecture exists to avoid.
- 5 backup/restore procedures, 5 failover procedures, 5 upgrade paths, 5 security reviews; RTO < 15 min must
  hold for the *slowest* of them.
- Cross-store consistency during restore: restoring Postgres to T-5min while Elasticsearch is at T means the
  system is *silently* incoherent after recovery.
- Enormous fixed operational cost paid at day one for scale reached (if ever) in year three.

### C. Distributed SQL (CockroachDB / Yugabyte)

**Advantages**
- Horizontal write scaling and multi-region survivability with familiar SQL; strong consistency across regions.
- Directly addresses NFR-601 (residency) with per-row geo-partitioning.

**Disadvantages**
- Higher latency per transaction, especially cross-region; the workflow engine's read-modify-write hot path
  would suffer.
- Weaker/absent ecosystem support for the specific features we rely on (RLS semantics, `pgvector`, mature
  logical replication tooling, PITR maturity).
- Operationally unfamiliar; the failure modes are subtle and the on-call cost is real.
- Solves a write-scaling problem we do not yet have, at a latency cost we would pay immediately.

### D. Managed serverless (Aurora Serverless, Neon, etc.)

**Advantages:** elastic cost, low ops, fast branching for testing.
**Disadvantages:** cold-start and scaling-event latency spikes conflict with NFR-101; less control over
extensions and replication topology; vendor lock-in on the most expensive-to-move component.

## Decision

**PostgreSQL 16 is the primary and authoritative datastore for all business state.**

Specifically:
- **Authoritative:** domain state, event store, outbox/inbox, workflow runs, audit, usage records, embeddings
  (initially), full-text (initially).
- **Non-authoritative and permitted elsewhere:** caches and rate limits (Redis, INV-08), search indexes and
  vector indexes once scale demands (OpenSearch / Qdrant), analytical copies (warehouse export).

Deferred-adoption thresholds are pre-committed here so that the decision to add a store is evidence-driven
rather than aesthetic:

| Add this store | When this is measured |
|----------------|----------------------|
| OpenSearch (search) | Postgres FTS p95 > 300 ms on the search endpoint at production cardinality, **or** faceting/analyzer requirements (FR-505) cannot be met |
| Qdrant (vectors) | > ~50 M chunks per region **or** pgvector ANN recall@10 < 0.90 at required latency ([ADR-008](ADR-008-vector-database.md)) |
| ClickHouse (metering rollups) | Usage aggregation p95 > 2 s despite pre-aggregation, **or** > ~5 B usage rows/region |
| Read replicas | Primary CPU > 60 % sustained with > 70 % read traffic |

## Why

The single-transaction property is worth more than per-workload optimality, because the failure it prevents
(silent divergence between state and events) is *undetectable at write time* and *expensive to reconcile
afterward*, whereas the failure that polyglot persistence prevents (a slow query) is loud, measurable, and
fixable incrementally.

We also deliberately choose to pay operational cost **later and conditionally** rather than **now and
unconditionally**, and we make that conditionality explicit with the thresholds table above so it is a plan
rather than a hope.

## Schema strategy

- **Partitioning:** `RANGE` by time on `events`, `audit_records`, `usage_records`, `outbox_messages`;
  `HASH` by `organization_id` on `workflow_runs` and `step_executions` to spread lock contention and permit
  per-tenant maintenance. Details: [partitioning](../06-data/partitioning.md).
- **JSONB:** used for genuinely open-ended payloads (event bodies, step inputs/outputs, agent configuration
  overrides) — never for fields that are queried as first-class predicates, which get real columns.
- **Isolation levels:** `READ COMMITTED` by default; `REPEATABLE READ` with retry for aggregate writes that
  perform read-modify-write; explicit optimistic version columns rather than `SELECT FOR UPDATE` on hot rows.
  Rationale and deadlock analysis: [database-architecture](../06-data/database-architecture.md).
- **Connection management:** PgBouncer in transaction mode; per-role pool budgets so one role cannot exhaust
  the pool (mitigation from [ADR-001](ADR-001-architecture-style.md)).

## Consequences

- All migrations follow expand → migrate → contract (INV-11), enforced by a migration linter.
- RLS policies are mandatory on every business table (INV-14a).
- Long-running analytical queries are forbidden on the primary; they run on replicas or the warehouse export.
- Any proposal to add a datastore must cite a measured threshold from the table above, in an ADR.

## Failure modes

| Failure mode | Detection | Mitigation |
|--------------|-----------|------------|
| Primary loss | Health checks; replication lag alert | Streaming replica + automated failover; PITR for corruption ([DR](../07-infrastructure/disaster-recovery.md)) |
| Connection exhaustion | Pool saturation metric per role | PgBouncer; per-role budgets; statement timeouts |
| Table bloat on high-churn tables (runs, leases) | Dead-tuple ratio; autovacuum lag | Aggressive per-table autovacuum settings; partition rotation; `HOT` friendly updates |
| Long transaction blocks vacuum → bloat cascade | `idle_in_transaction` and oldest-xact alerts | `idle_in_transaction_session_timeout`; no user-facing long transactions |
| Lock contention on hot tenant rows | Lock-wait metrics; deadlock counter | Optimistic concurrency; hash partitioning; per-tenant queues |
| Partition maintenance not keeping up | Missing future partition alert | Scheduled partition pre-creation job with alerting on lag |
| Logical corruption from a bad migration | Post-migration verification; anomaly alerts | Expand/contract discipline; PITR to pre-migration timestamp; rehearsed restores |
| pgvector index build blocking writes | Build duration monitoring | `CONCURRENTLY` builds; build on replica then promote where possible |

## Operational impact

Adds: partition lifecycle management, vacuum tuning, replication monitoring, and monthly restore rehearsals
(NFR-205). Avoids: four additional on-call learning curves. Runbooks:
[database runbooks](../12-operations/runbooks/).

## Cost impact

One well-sized primary + one replica per region is dramatically cheaper than five clusters. The main cost risk
is over-provisioning the primary to avoid partitioning work; the partitioning plan exists to prevent that.

## Security impact

Strongly positive: RLS provides isolation that survives application bugs. Encryption at rest via storage-layer
encryption plus envelope encryption for credentials (INV-18). One audit surface. The concentration risk — one
store holding everything — is mitigated by RLS, least-privilege database roles per process role, and no shared
superuser in application paths.

## Scalability impact

See [capacity planning](../10-performance/capacity-planning.md) for the modeled row counts at 10⁴ → 10⁸ users.
Summary of where PostgreSQL alone stops being sufficient:

| Scale | Status | Action |
|-------|--------|--------|
| 10 M rows/table | Comfortable | Nothing |
| 100 M rows/table | Fine with partitioning + correct indexes | Partition, watch index bloat |
| 1 B rows/table | Requires partitioning, careful index design, archival tiering | Time partitions + cold storage offload |
| 10 B rows/table | Beyond a single primary for the hot path | Shard by tenant (dedicated tier, [ADR-009](ADR-009-multi-tenancy.md)) + offload append-only analytics to ClickHouse |

The escape from a single primary is **tenant sharding**, not resharding a global table — which is why
[ADR-009](ADR-009-multi-tenancy.md) requires that no query ever spans tenants.

## Related decisions

[ADR-001](ADR-001-architecture-style.md) · [ADR-003](ADR-003-event-bus.md) ·
[ADR-005](ADR-005-event-sourcing.md) · [ADR-008](ADR-008-vector-database.md) ·
[ADR-009](ADR-009-multi-tenancy.md) · [ADR-010](ADR-010-consistency-model.md)

## Related code

`apps/control-plane/db/` · `apps/control-plane/infrastructure/database/` ·
`tools/migration-lint/`

## Related diagrams

[Data flow](../02-architecture/data-flow.md) · [Schema](../06-data/schema.md) ·
[Partitioning](../06-data/partitioning.md)
