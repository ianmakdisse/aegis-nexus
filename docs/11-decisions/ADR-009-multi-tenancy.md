# ADR-009 — Multi-Tenancy: Hybrid (Shared Schema + RLS Pool, Database-per-Tenant Dedicated Tier)

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-09 |
| **Deciders** | Principal Architect, Database Architect, Security Engineer, CISO proxy |
| **Supersedes** | — |

---

## Context

Aegis Nexus must serve, simultaneously:

- a 3-person company on a self-serve plan, one of thousands in a shared pool;
- a 40,000-employee enterprise with a contractual requirement that its data reside in named infrastructure,
  in a named region, with independently restorable backups;
- everything in between, including tenants that grow from the first into the second.

These are not the same product technically. Serving both from one topology means either over-paying for the
small tenants or under-serving the large ones. The interesting question is not "which model?" but **"how do we
support both without forking the codebase?"**

## Requirements driving this decision

FR-101 (tenant is root isolation unit) · FR-102 (three-layer isolation) · FR-103 (1 → 10⁵ tenants plus
dedicated) · FR-104 (promotion path, < 15 min write-freeze for 500 GB) · NFR-403 (noisy-neighbor containment) ·
NFR-601 (residency) · NFR-203/204 (RPO/RTO) · INV-13, INV-14.

## Considered alternatives

### A. Shared database, shared schema (`organization_id` column + RLS)

**Advantages**
- Lowest cost per tenant by a wide margin; one connection pool, one buffer cache, one set of indexes.
- One migration run for everyone; schema drift is impossible.
- Onboarding a tenant is an `INSERT`, so signup is instant and free.
- Cross-tenant platform analytics are trivial (aggregate queries over one table).
- RLS provides isolation *in the database*, surviving application bugs.

**Disadvantages**
- Noisy neighbors share buffer cache, connections, autovacuum, and lock contention.
- Blast radius of a bad query, a bad migration, or a corrupted table is every tenant.
- Per-tenant PITR is not natively possible: restoring one tenant to T-1h means extracting rows from a restored
  copy, not restoring the cluster.
- Residency is per-cluster, so a single cluster cannot satisfy conflicting residency requirements.
- Some enterprise procurement processes simply refuse it, regardless of technical merit.

### B. Shared database, schema per tenant

**Advantages:** clearer logical separation; per-schema `pg_dump`; some noisy-neighbor mitigation at the object level.
**Disadvantages:** **10⁵ schemas × ~40 tables = 4 M relations** — `pg_catalog` degrades badly, `pg_dump`/restore
becomes impractical, and every migration is 10⁵ DDL statements with no atomicity across them. Connection
pooling with `search_path` switching is error-prone in transaction-pooling mode. This option looks like a
compromise and is in practice the worst of both. **Rejected.**

### C. Database per tenant

**Advantages:** strongest isolation; per-tenant PITR, residency, and resource limits; per-tenant restore is a
normal restore; noisy neighbors are impossible.
**Disadvantages:** cost floor per tenant is high (a database instance/allocation each); 10⁵ databases is an
operational impossibility with our team; migrations become an orchestrated fleet operation with partial-failure
states; cross-tenant analytics requires a separate pipeline; connection management multiplies.

### D. Hybrid *(chosen)*

Pool tier = (A). Dedicated tier = (C). **One codebase, one schema definition, tenant tier resolved at
connection time.**

**Advantages**
- Each tenant gets the trade-off appropriate to its size, price, and contractual posture.
- The dedicated tier is also the **scaling escape hatch**: a tenant too large for the pool moves out instead of
  forcing the pool to grow.
- Residency (NFR-601) is satisfiable per tenant without partitioning the entire product.
- Because both tiers run identical schema and code, a bug fixed once is fixed everywhere.

**Disadvantages**
- Two operational modes to run, monitor, and rehearse. Migrations must succeed against N+1 targets, with
  partial-failure handling.
- The promotion path (FR-104) is real engineering work and must be rehearsed or it will not work when needed.
- Connection routing becomes a correctness-critical component: routing a request to the wrong database is a
  breach, so the router is security-sensitive code.

## Decision

**Adopt the hybrid model.**

| | Pool tier | Dedicated tier |
|---|-----------|----------------|
| Storage | Shared cluster, shared schema, `organization_id` + RLS | Own database (own cluster for the top tier) |
| Isolation | RLS + app scoping + request context | Physical + all pool-tier layers retained |
| Residency | Per-cluster (tenant placed in a conforming cluster) | Per-tenant, arbitrary region |
| PITR | Cluster-level; per-tenant restore via extract-and-merge | Native per-tenant PITR |
| Noisy neighbors | Managed by quotas + fair dispatch | Structurally impossible |
| Migrations | One run | Fleet run, tracked per tenant |
| Cost | Marginal | Meaningful fixed cost |
| Backbone topic | Shared topics, tenant-hashed partition key | Dedicated topics available |
| Onboarding | Instant | Provisioning workflow (minutes) |

**Isolation is identical in kind at both tiers** — the dedicated tier *adds* a physical layer, it never
*replaces* the logical ones. Removing RLS "because this tenant has its own database" is forbidden: it would
create a tenant whose isolation depends on a single routing decision.

### The three enforcement layers (INV-14), concretely

| Layer | Mechanism | Fails how |
|-------|-----------|-----------|
| (a) Database | RLS policy `organization_id = current_setting('nexus.organization_id')::uuid` on every business table | Query returns zero rows |
| (b) Application | Default scope on every model; a base query object that requires tenant context | Raises before SQL is built |
| (c) Context | Request/job-scoped `Nexus::Tenancy::Context`, set at the edge, propagated into jobs, events, cache keys, search filters, and prompts. **Absent context raises** | Raises immediately (fail closed) |

The isolation test suite disables each layer in turn and asserts the remaining two still deny. A layer that
cannot be tested this way is not a layer.

### Tenant placement and routing

- `organizations.placement` records tier, cluster/database identifier, and region.
- A **tenant resolver** at the edge maps the authenticated principal → organization → placement, and opens the
  correct connection. This runs before any domain code.
- Placement is cached with a short TTL and **verified against the connection actually in use** before the first
  query (defense against a stale cache producing a cross-tenant connection — a routing bug that RLS would then
  catch, because the session variable and the database would disagree).

### Promotion path (FR-104), summarized

1. Provision the target database; run migrations; verify schema parity by checksum.
2. Start **logical replication** of the tenant's rows into the target (filtered publication).
3. Let replication catch up; verify row counts and checksums per table.
4. **Freeze writes for the tenant only** (tenant-scoped write gate; other tenants unaffected).
5. Drain in-flight workflow steps to a safe point; the workflow engine's durable state makes this a pause, not a loss.
6. Final catch-up; flip `placement`; invalidate resolver caches.
7. Unfreeze. Verify. Retain source rows read-only for a rollback window, then purge.

Full procedure with rollback: [tenant promotion runbook](../12-operations/runbooks/tenant-promotion.md).
It is rehearsed quarterly against a synthetic tenant, because an unrehearsed migration procedure is a
document, not a capability.

## Noisy-neighbor controls (pool tier)

Isolation of *data* is not isolation of *resources*. Both are required:

| Resource | Control |
|----------|---------|
| Database connections | Per-role pool budgets; statement timeouts |
| Worker capacity | Weighted fair dispatch per tenant; per-tenant concurrency caps |
| Event backbone | Composite partition key `hash(org_id, aggregate_id)`; per-tenant lag monitoring |
| API requests | Per-tenant + per-endpoint rate limits |
| AI provider quota | Per-tenant concurrency caps ([ADR-007](ADR-007-ai-runtime.md)) |
| Storage | Per-tenant quotas with soft/hard thresholds |

## Consequences

- Every business table carries `organization_id`, non-null, indexed, with an RLS policy. A schema conformance
  test enforces this; the global allow-list is explicit and requires an ADR to extend.
- All background jobs carry tenant context explicitly; a job without it raises rather than running unscoped.
- Cache keys, search filters, vector-store calls, and prompt assembly all take tenant as a required parameter.
- Migrations run against pool + N dedicated databases with per-target status tracking and resumability.
- Platform-wide analytics reads from an export pipeline, never from a cross-tenant query on live data.

## Failure modes

| Failure mode | Detection | Impact | Mitigation |
|--------------|-----------|--------|------------|
| Missing tenant filter in a query | RLS denies; isolation suite | None in production (RLS catches) | Three layers; suite tests each independently |
| Tenant context missing in a job | Raises at job start | Job fails loudly | Fail closed by design |
| Resolver returns stale placement after promotion | Connection/session-variable mismatch check | Request fails rather than reads wrong data | Short TTL + post-connect verification |
| Bad migration on the pool cluster | Post-migration verification | All pool tenants affected | Expand/contract (INV-11); canary on a staging clone; PITR |
| Dedicated fleet migration partially fails | Per-target status | Some tenants on N, some on N+1 | N/N+1 compatibility is mandatory (INV-11), so mixed state is *safe*; resumable runner |
| One tenant saturates shared workers | Per-tenant throughput metrics | Others delayed | Fair dispatch + concurrency caps; promotion as the escalation |
| Cross-tenant leak via a cache key | Cache-key lint + isolation tests | **Breach** | Tenant-prefixed keys enforced by the cache wrapper (no raw client access) |
| Cross-tenant leak via search or vectors | Isolation suite covers these stores | **Breach** | Tenant is a required argument in both ports ([ADR-008](ADR-008-vector-database.md)) |
| Cross-tenant leak via an agent prompt | Prompt-assembly tests | **Breach** | Retrieval is tenant-scoped at the store; assembler takes tenant explicitly |

The last three rows exist because tenant isolation is usually broken *outside* the primary database — in
caches, indexes, and prompts. Enumerating them is the point.

## Operational impact

Two modes to operate; one schema to maintain. Per-tenant restore is easy on the dedicated tier and a documented
extract-and-merge procedure on the pool tier. Adds: placement management, promotion rehearsals, fleet migration
tooling.

## Cost impact

The pool tier keeps the marginal cost of a small tenant near zero, which is what makes self-serve viable. The
dedicated tier's cost is charged through to the tenants that require it. The hybrid deliberately avoids paying
dedicated-tier cost for the 99% of tenants that do not need it — the single largest cost decision in the platform.

## Security impact

Positive and central. Isolation is enforced by the database, not by developer discipline; the dedicated tier
provides a physical boundary for tenants whose risk posture requires one. The main new risk is the tenant
resolver: a routing bug is a breach. It is treated as security-critical code — reviewed accordingly, covered by
the isolation suite, and backstopped by the session-variable/connection consistency check.

## Scalability impact

The pool scales until a single primary cannot hold it; from that point, growth is absorbed by **moving large
tenants out**, which is a linear, well-understood operation — as opposed to resharding a global table, which is
not. This is why [ADR-002](ADR-002-database.md) forbids queries that span tenants: it is what keeps this escape
hatch available.

## Related decisions

[ADR-001](ADR-001-architecture-style.md) · [ADR-002](ADR-002-database.md) · [ADR-003](ADR-003-event-bus.md) ·
[ADR-008](ADR-008-vector-database.md) · [ADR-010](ADR-010-consistency-model.md)

## Related code

`apps/control-plane/domains/organizations/` · `infrastructure/tenancy/` ·
`infrastructure/database/tenant_resolver.rb` · `db/policies/`

## Related diagrams

[Tenant isolation](../08-security/tenant-isolation.md) ·
[Deployment architecture](../02-architecture/deployment-architecture.md) ·
[Multi-region](../07-infrastructure/multi-region.md)
