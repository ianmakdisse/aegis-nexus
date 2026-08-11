# ADR-010 — Consistency Model: Strong Where It Protects, Eventual Where It Scales, Declared Everywhere

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-09 |
| **Deciders** | Staff Distributed Systems, Principal Architect, Security Engineer |
| **Supersedes** | — |

---

## Context

"Eventually consistent" is often used as a synonym for "we didn't think about it". This ADR exists to make
consistency a *declared property per operation* rather than an emergent one, because the difference between an
acceptable staleness and a security vulnerability is not a technical distinction — it is a **which-decision-is-
being-made** distinction.

The same 300 ms of staleness is:

- **fine** when a dashboard shows 41 running workflows instead of 42;
- **a bug** when a user creates a workflow and doesn't see it in the list;
- **a vulnerability** when a revoked permission is still honored;
- **money** when a budget check uses a stale total and lets a runaway agent spend past its ceiling.

## Requirements driving this decision

FR-102/108 (isolation, deny-by-default) · FR-204 (outbox) · FR-205 (per-key ordering) ·
FR-208 (rebuildable projections) · FR-702 (budget enforcement) · FR-801 (audit) · NFR-101 · INV-04, INV-05,
INV-09, INV-15.

## Considered alternatives

### A. Strong consistency everywhere (single-node semantics, synchronous everything)
**Advantages:** simplest mental model; no staleness bugs; no reconciliation tooling.
**Disadvantages:** forces synchronous cross-context calls (violating INV-03), makes every dashboard query
compete with the workflow hot path, and caps write throughput at the primary's ability to also serve reads.
Genuinely impossible at the modeled scale for the read paths.

### B. Eventual consistency everywhere (CQRS/event-driven by default, no exceptions)
**Advantages:** uniform; every read path optimizable; maximum decoupling.
**Disadvantages:** authorization and budget enforcement become racy by construction. A revoked role that is
honored for another 200 ms is a *security* property degraded for a *performance* reason nobody asked for.
Read-your-writes must then be simulated everywhere, which reintroduces coordination in a worse form.

### C. Declared consistency per operation class *(chosen)*

## Decision

**Consistency is a property each operation declares, drawn from a fixed vocabulary. Nothing is left implicit.**

### The vocabulary

| Class | Guarantee | Where used |
|-------|-----------|------------|
| **Strong (transactional)** | Read-your-writes; serializable outcome within one aggregate/transaction | Authorization, budget enforcement, approval redemption, workflow state transitions, identity, tenancy |
| **Read-your-writes (session)** | The writer sees its own write immediately; others may lag | API responses returning the object the command produced |
| **Bounded staleness** | Stale by at most a declared budget, alerted when exceeded | Projections, dashboards, lists, timelines, search |
| **Convergent** | Will agree eventually; order not guaranteed; duplicates harmless | Cross-context reactions, notifications, analytics rollups |
| **Best-effort** | May be lost entirely without correctness impact | WebSocket pushes, cache warms, presence |

### The three rules that follow

**Rule 1 — Anything that can deny an action reads authoritative state.**
Authorization checks, budget checks, approval-token redemption, quota checks, and idempotency checks read the
row, in a transaction, never a projection or cache. This is [ADR-004](ADR-004-cqrs.md)'s boundary restated as a
constitutional consequence of INV-15: a decision that *permits* something based on stale data is a
vulnerability, and no latency budget justifies it.

**Rule 2 — Everything eventually consistent declares source, budget, staleness behavior, and rebuild.**
Undeclared eventual consistency is a defect; `docs-lint` fails a projection without a declaration.

**Rule 3 — Convergence is verified, not assumed.**
A scheduled reconciliation compares derived state against source state per tenant and alerts on divergence.
Systems that only *believe* they converge diverge silently for months.

### Applied to the platform

| Operation | Class | Notes |
|-----------|-------|-------|
| Authorization decision | Strong | INV-15; never cached beyond a request |
| Permission revocation visibility | Strong | Revocation invalidates the principal's token cache synchronously |
| Budget check before AI spend | Strong | Reads `budgets` + reserved amount in a transaction; rollups are for display only |
| Approval token redemption | Strong | Single-use, transactional; replay attempt is a hard failure + security event |
| Workflow step transition | Strong | Optimistic concurrency on the run; a losing writer retries |
| Idempotency/dedup check | Strong | Unique constraint is the mechanism, not a lookup |
| Event → projection | Bounded staleness (500 ms–2 s p95) | Declared per projection ([ADR-004](ADR-004-cqrs.md)) |
| Cost rollups | Bounded staleness (5 min) | Enforcement never reads these |
| Search / knowledge index | Bounded staleness (2 s / 60 s) | UI shows index lag explicitly |
| Cross-context reaction (e.g. workflow → notification) | Convergent | At-least-once + idempotent handler |
| WebSocket push | Best-effort | Durable record always in Postgres; UI self-heals |
| Audit record write | Strong | Written in the same transaction as the audited action; never async |

That last row deserves emphasis: **audit is not eventually consistent.** An audit trail that can lag can also
lose, and a lost audit record is indistinguishable from an unaudited action.

### Ordering

Per-key ordering only (INV-09, FR-205). Concretely:

- Events for the same aggregate arrive in production order; events for different aggregates do not.
- Wall-clock timestamps from different nodes must never be used to infer causality. Causality is expressed by
  `causation_id` and by per-stream sequence numbers.
- Projectors are **order-tolerant**: they apply by sequence and ignore already-applied sequences, so a redelivery
  or a brief out-of-order window is a no-op rather than a corruption.

### Read-your-writes without coordination

For CQRS contexts, the API returns the command's own result rather than re-reading a projection. This gives the
writer immediate consistency with zero coordination and avoids the "poll until it appears" anti-pattern that
turns a 5 ms write into a 300 ms request.

Where a client genuinely must observe its write in a *list* view, the response carries a
`consistency_token` (the stream position) that the client may pass to the list endpoint; the endpoint waits up
to a small bound for the projection to reach that position, then returns with an explicit `stale: true` flag if
it did not. Waiting is bounded and visible — never infinite, never silent.

## Consequences

- Every projection carries a declaration block in its context README (CI-enforced).
- Reconciliation jobs exist per derived store and report divergence per tenant.
- Authorization and budget code paths are forbidden from importing projection models — enforced by a lint rule
  on module imports, because this is the rule most likely to be broken by a well-meaning performance fix.
- Staleness is surfaced in the UI rather than hidden; users tolerate visible lag and lose trust in invisible lag.

## Failure modes

| Failure mode | Detection | Impact | Mitigation |
|--------------|-----------|--------|------------|
| Projector lag beyond budget | Lag SLI per projection | Stale UI | Alert + runbook; UI shows lag badge |
| Silent divergence (projection wrong, not late) | Scheduled reconciliation | Wrong data trusted | Reconciliation is the only reliable detector — hence Rule 3 |
| Authorization reads a cache after a revocation | Authz test suite; revocation invalidation test | **Privilege escalation** | Rule 1 + synchronous invalidation + short token TTL |
| Budget enforced on a stale rollup | Cost-governance test | Overspend past ceiling | Rule 1: enforcement reads authoritative rows + reservations |
| Duplicate event applied twice | Applied-sequence check | Double-counted metric | Order-tolerant, idempotent projectors (INV-05) |
| Causality inferred from timestamps | Code review; clock-skew metric | Wrong reconstruction of history | `causation_id` is the only causal mechanism |
| Consistency token wait becomes unbounded | Endpoint latency SLI | Latency regression | Hard bound + explicit `stale: true` response |
| Rebuild serves partial data | Rebuild procedure test | Wrong reads during rebuild | Shadow table + atomic swap (UC-07) |

## Operational impact

New on-call concepts: projection lag, reconciliation divergence, rebuild progress. Each has a runbook. The
benefit is that "is this stale or is this wrong?" — normally the hardest question in an event-driven system —
has a mechanical answer: check lag (stale) vs. reconciliation (wrong).

## Cost impact

Reconciliation jobs and shadow rebuilds cost compute. Cheap relative to the cost of discovering divergence via
a customer, which is how systems without reconciliation always discover it.

## Security impact

This ADR's central contribution is security, not performance: it fixes the rule that **anything capable of
denying an action reads strongly consistent state**, and makes violating that rule a lint failure rather than a
judgment call under deadline pressure.

## Related decisions

[ADR-003](ADR-003-event-bus.md) · [ADR-004](ADR-004-cqrs.md) · [ADR-005](ADR-005-event-sourcing.md) ·
[ADR-006](ADR-006-workflow-engine.md) · [ADR-009](ADR-009-multi-tenancy.md)

## Related code

`apps/control-plane/infrastructure/projections/` · `domains/authorization/` ·
`domains/billing/internal/enforcement/` · `infrastructure/consistency/`

## Related diagrams

[Consistency model](../04-distributed-systems/consistency-model.md) ·
[Ordering guarantees](../04-distributed-systems/ordering-guarantees.md) ·
[Data flow](../02-architecture/data-flow.md)
