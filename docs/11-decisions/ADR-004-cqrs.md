# ADR-004 — CQRS Applied Selectively, Not Universally

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-09 |
| **Deciders** | Principal Architect, Staff Distributed Systems |
| **Supersedes** | — |

---

## Context

CQRS separates the model used to change state from the model used to read it. It is frequently applied as a
project-wide style, which is a mistake: it doubles the number of models, introduces eventual consistency into
places that did not need it, and forces users to confront staleness in workflows where they expect
read-your-writes.

The honest test for CQRS is: **do the read requirements and the write requirements genuinely conflict?**
They conflict when reads need shapes, aggregations, or index structures that would distort or slow the write
model. They do not conflict merely because a system is large or event-driven.

Applying that test across our contexts:

| Context | Write pattern | Read pattern | Conflict? |
|---------|--------------|--------------|-----------|
| Identity, Organizations, Authorization | Low-volume CRUD | Point lookups, small joins, must be immediately consistent after a write | **No** |
| Integrations, Notifications config | Low-volume CRUD | Simple lists | **No** |
| Workflow runtime | Very high-volume append of step executions, contended run rows | Timelines, dashboards, "runs by status/tenant/definition", aggregate counts across millions of runs | **Yes, severely** |
| Agent executions | High-volume append of steps, tool calls, token usage | Timelines, cost rollups, per-agent analytics | **Yes** |
| Events | Append-only ingest at high rate | Faceted exploration, search, correlation-tree traversal | **Yes** |
| Billing / usage | Extremely high-volume inserts | Aggregations by many dimensions over long windows | **Yes, severely** |
| Documents / knowledge | Moderate writes | Vector + keyword hybrid retrieval | **Yes** (different storage entirely) |
| Audit | Append-only, hash-chained | Filtered timelines, compliance export | **Yes** (mild) |

Adding CQRS to the first two rows would make "create a user, then immediately list users" flaky for no
benefit. Refusing CQRS in the last six would mean serving dashboards from tables that are simultaneously the
hot write path — the classic cause of "the dashboard query locked the workflow engine".

## Requirements driving this decision

FR-308 (per-run timelines) · FR-505 (enterprise search) · FR-701/703 (cost attribution and metering
aggregation) · NFR-101/102 (API latency) · NFR-402 (no global hot spot) · FR-208 (projections rebuildable).

## Considered alternatives

### A. CQRS everywhere
**Advantages:** uniformity; one mental model; every read path is optimizable.
**Disadvantages:** eventual consistency where users expect immediacy (settings pages, permission changes —
a permission change that takes 300 ms to appear is a *security* surprise); double the models to maintain;
double the rebuild tooling; onboarding cost for every trivial feature.

### B. No CQRS — serve everything from the write model
**Advantages:** simplest; strong consistency everywhere.
**Disadvantages:** dashboard and analytics queries on the write tables cause lock contention and plan
instability on the workflow hot path; index proliferation slows writes; the timeline query for a run with
50k step executions cannot be made fast without a purpose-built shape.

### C. Selective CQRS *(chosen)*
Apply CQRS only where the conflict test above is positive; keep simple contexts as plain transactional CRUD.

**Advantages:** complexity is paid where it buys something; read-your-writes preserved where users expect it;
fewer projections to rebuild and monitor.
**Disadvantages:** two idioms in one codebase — engineers must know which context they are in. Mitigated by
making the split *contextual* (a whole context is either CQRS or not) rather than per-endpoint.

## Decision

**CQRS is applied at the bounded-context level, to: Workflow Runtime, Agents, Events, Billing/Usage,
Documents/Knowledge, and Audit. It is explicitly not applied to: Identity, Organizations, Authorization,
Integrations configuration, or Notifications configuration.**

Rules:

1. A CQRS context has a `commands/` side (validation → domain → events) and a `projections/` side (event
   handlers writing read models). Queries never touch write tables; commands never read projections for
   decision-making.
2. **Non-CQRS contexts are strongly consistent and stay that way.** Authorization in particular must never
   become eventually consistent — a revoked permission that is still honored for 200 ms is a vulnerability,
   not a latency budget.
3. Every projection declares: its source events, its rebuild procedure, its expected lag, and its behavior
   when stale. This declaration is mandatory and CI-checked ([docs-lint](../../tools/docs-lint/README.md)).
4. Every projection is rebuildable from the event store with no vendor assistance (FR-208).
5. Read-your-writes, where required by UX inside a CQRS context, is provided by returning the command's
   result directly (the API returns what the command produced) — **not** by reading the projection in a loop.

## Staleness budgets

Every eventually consistent read path has a declared budget, alerted on when exceeded:

| Projection | Source | Target lag (p95) | Alert | Behavior when stale |
|-----------|--------|------------------|-------|---------------------|
| Workflow run list/status | workflow events | < 500 ms | > 5 s | UI shows "updating…" badge; run detail reads authoritative row |
| Run timeline | step execution events | < 1 s | > 10 s | Partial timeline with explicit "more events pending" marker |
| Agent execution timeline | agent events | < 1 s | > 10 s | Same |
| Event explorer index | ingested events | < 2 s | > 30 s | Explicit "index lag: Ns" indicator |
| Cost rollups (hourly) | usage records | < 5 min | > 20 min | Dashboard timestamps the rollup; budget *enforcement* does not use rollups |
| Audit timeline | audit records | < 2 s | > 30 s | Compliance export always reads authoritative records, never the projection |
| Knowledge index | document events | < 60 s (post-ingest) | > 10 min | Document shows `indexing` state until available |

> **Critical rule embedded above:** budget *enforcement* (FR-702) and *authorization* never read a projection.
> Anything that can deny an action reads the authoritative row. Projections serve display and analysis.
> This is the boundary between "eventual consistency is fine" and "eventual consistency is a vulnerability".

## Why

Selective application preserves the property that makes CQRS valuable (read models shaped for reading) while
avoiding the property that makes it expensive (eventual consistency as a global tax). The context-level split
keeps the rule learnable: engineers ask "which context am I in?", not "is this particular endpoint CQRS?".

## Consequences

- Projections are code with tests, including out-of-order and duplicate event tests.
- A `rebuild` task exists per projection; rebuild uses a shadow table + atomic swap (UC-07) so rebuilds never
  serve partial data.
- Projection lag is a first-class SLI (NFR-501).
- Adding a projection requires documenting it in the context's README; docs-lint fails otherwise.

## Failure modes

| Failure mode | Detection | Impact | Mitigation |
|--------------|-----------|--------|------------|
| Projector crashes | Consumer lag alert | Stale reads, growing | Restart from committed offset; idempotent projectors (INV-05) |
| Projector bug writes wrong data | Data-quality checks; user reports | Wrong dashboards; **never wrong source of truth** | Fix + rebuild via shadow swap; source events untouched |
| Rebuild takes too long at scale | Rebuild duration benchmark | Extended staleness during recovery | Parallel rebuild by partition key; snapshot-assisted start; rebuild on replica |
| Out-of-order event application | Version/sequence gap counter | Corrupt projection row | Projectors are order-tolerant: they apply by sequence and ignore already-applied sequences |
| Duplicate event application | Inbox dedup + per-projection applied-sequence | None | Idempotent apply |
| Silent divergence between projection and source | Periodic reconciliation job comparing counts/checksums per tenant | Undetected wrong data | Scheduled reconciliation with alerting — the only reliable defense |
| Engineer reads a projection for an authorization decision | Code review + lint rule on authorization module imports | **Security bug** | Explicit rule (above); authorization context is non-CQRS by design |

## Operational impact

New on-call concepts: projection lag, rebuild jobs, reconciliation results. Each has a runbook
([projection lag runbook](../12-operations/runbooks/projection-lag.md)).

## Cost impact

Extra storage for read models (modest — projections are small relative to event volume) and extra compute for
projectors. Offset by removing analytical load from the primary's hot path, which is the more expensive
resource.

## Security impact

Positive where applied correctly (analytical queries run against data that has already been permission-scoped
at projection time), negative if misused (a projection missing a tenant filter is a cross-tenant leak).
Therefore projections are subject to the same RLS and tenant-scoping rules as any other table (INV-13/INV-14),
with no exception for "derived" data.

## Scalability impact

This is the main lever that keeps NFR-101/102 achievable as run and event volumes grow: read paths scale
independently of write paths, and expensive reads can be moved to replicas or purpose-built stores without
touching the domain.

## Related decisions

[ADR-002](ADR-002-database.md) · [ADR-003](ADR-003-event-bus.md) · [ADR-005](ADR-005-event-sourcing.md) ·
[ADR-010](ADR-010-consistency-model.md)

## Related code

`apps/control-plane/domains/*/projections/` · `infrastructure/projections/`

## Related diagrams

[CQRS](../04-distributed-systems/cqrs.md) · [Data flow](../02-architecture/data-flow.md)
