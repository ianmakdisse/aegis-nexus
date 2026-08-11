# The Architecture Constitution

> **Status:** ratified · **Version:** 1.0 · **Amendment procedure:** §Amendments below
>
> This document defines the **non-negotiable invariants** of Aegis Nexus. Everything else in `/docs` is
> explanation, guidance, or record. This is law.
>
> Every invariant has a stable ID (`INV-xx`). Code, tests, reviews, and ADRs cite these IDs.
> **A pull request that violates an invariant is rejected, or it amends the Constitution — never neither.**

---

## Why a constitution at all

Large systems do not decay through single catastrophic decisions. They decay through hundreds of locally
reasonable ones: a query that "just this once" reaches into another context's table; an event published outside
its transaction because the refactor was awkward; a tenant filter omitted in a background job that "only admins
run anyway".

Each of those is defensible in isolation and fatal in aggregate. The purpose of this document is to make the
small, local, reasonable-seeming violation **visibly illegal**, so that it must be argued explicitly rather
than merged quietly.

A constitution is only worth writing if it is enforced. Where an invariant can be checked by a machine, it
**is** checked by a machine — the enforcement column below is not aspirational.

---

## Part I — Boundaries

### INV-01 — A bounded context owns its tables exclusively
No module may read from or write to another context's tables, directly or via a join, ever. Cross-context data
is obtained through that context's published contract (a command, a query object, or a subscribed event).

**Why:** shared tables are shared schemas; shared schemas are a distributed monolith with none of the benefits
and all of the coupling. This invariant is what preserves the option to extract a context into its own service
([ADR-001](../11-decisions/ADR-001-architecture-style.md)) without a rewrite.

**Enforcement:** static boundary check in CI (`tools/boundary-check`), which parses model/table ownership and
fails on cross-context table references.
**Escape hatch:** none. If you need another context's data, add to its published contract.

### INV-02 — The published contract is the only public surface
Everything inside `domains/<context>/internal/` is private. Callers depend on `domains/<context>/`
top-level classes only.

**Why:** without a declared surface, every class becomes a de-facto API and refactoring becomes impossible.
**Enforcement:** CI boundary check; `internal/` references from outside the owning context fail the build.

### INV-03 — Contexts communicate asynchronously by default
Synchronous cross-context calls are allowed only where the caller genuinely cannot proceed without the answer,
and must be listed in the [context map](context-map.md) with a justification.

**Why:** synchronous coupling turns another context's latency and downtime into yours.

---

## Part II — Distributed correctness

### INV-04 — No dual writes
State changes and their event publications occur in one atomic step: write domain state and the outbox row in
the same database transaction. Publishing to an external broker inside a transaction, or after commit without
an outbox, is forbidden.

**Why:** the commit-then-crash window silently desynchronizes the system, and the resulting inconsistency is
undetectable without reconciliation tooling nobody builds until after the incident.
**Enforcement:** all event emission goes through `Nexus::Events::Publisher`, which requires an open transaction
and raises otherwise; a lint rule forbids direct broker client usage outside the relay.
→ [Outbox pattern](../04-distributed-systems/outbox-pattern.md)

### INV-05 — Every distributed operation is idempotent
Any handler that can be invoked more than once with the same logical input must produce the same result and
the same side effects as a single invocation.

**Why:** at-least-once delivery is not a defect to be engineered away; it is the substrate. Duplicates *will*
arrive. The only question is whether they are harmless.
**Enforcement:** consumers must declare a dedup key; the base consumer refuses to run a handler without one.
→ [Idempotency](../04-distributed-systems/idempotency.md)

### INV-06 — We never claim exactly-once delivery
Documentation, code comments, marketing, and API descriptions state *at-least-once delivery with
effectively-once processing*. 

**Why:** the claim is false for any system with external side effects, and believing it causes engineers to
skip INV-05.

### INV-07 — Durable execution state never lives in process memory
Workflow runs, agent executions, and any operation that may outlive a request must persist their resumption
state in PostgreSQL before the operation can be considered in progress.

**Why:** a deploy is a mass process kill. If a deploy can lose work, every deploy is an incident.
**Enforcement:** chaos test `worker-kill-mid-step` runs in CI against the workflow engine.

### INV-08 — Redis is never the source of truth for durable business state
Redis holds caches, rate-limit counters, ephemeral coordination, and locks. Losing the entire Redis cluster
must cause degraded performance, never data loss or incorrect business outcomes.

**Why:** Redis persistence is best-effort, failover loses writes, and treating it as durable is how "we lost
three hours of approvals" happens.
**Enforcement:** review checklist; any `Redis` write of business state requires an ADR.

### INV-09 — Ordering is per-key, never global
The system guarantees ordering only among messages sharing a partition key. No component may assume global
ordering, wall-clock ordering across nodes, or that "later timestamp" means "happened after".

→ [Ordering guarantees](../04-distributed-systems/ordering-guarantees.md)

---

## Part III — Evolution & compatibility

### INV-10 — Events are versioned and additively evolved
Every event carries `type` and `version`. Within a major version: fields may be added; fields may not be
removed, renamed, or have their meaning or type changed. Breaking changes create a new version, and the old
version keeps being handled until no stored event uses it.

**Why:** the event log is permanent. A breaking schema change is a breaking change to *history*, not just to
future messages.
**Enforcement:** CI schema-compatibility check against the registered baseline.

### INV-11 — Schema changes are safe for rolling deployment
Version N and N+1 of the application must both run correctly against the intermediate database schema.
Therefore: expand → migrate → contract, across separate deploys. Never rename or drop a column in the same
deploy that stops using it.

**Why:** rolling deploys mean two code versions run simultaneously, by design. A "simple rename" is an outage.
**Enforcement:** migration linter rejects destructive operations without a recorded prior expand migration.

### INV-12 — A workflow run is pinned to its definition version
Publishing a new workflow version must never alter the behavior of an in-flight run.

**Why:** mutating a running program's instructions is the most direct route to corrupt business state, and the
resulting damage is silent and unbounded.

---

## Part IV — Tenancy & security

### INV-13 — Every business row is attributable to exactly one tenant
`organization_id` is present, non-null, and indexed on every business table. Platform-global tables are
enumerated explicitly in [tenant-isolation.md](../08-security/tenant-isolation.md) and require an ADR to add to.

### INV-14 — Tenant isolation is enforced at three independent layers
(a) PostgreSQL RLS, (b) application-level default scoping, (c) request/job-scoped tenant context that
**fails closed** when absent. Removing any one layer must not produce a leak.

**Why:** one layer is one bug away from a breach. The layers must fail independently.
**Enforcement:** isolation test suite disables each layer in turn and asserts the others still deny.

### INV-15 — Authorization is deny-by-default and centrally evaluated
No grant means denied. Decisions come from the authorization context's evaluator; ad-hoc permission logic in
controllers, jobs, tools, or views is forbidden.

### INV-16 — Delegated authority only narrows
An agent's or service's effective permissions are the **intersection** of its own grants and those of the
principal it acts for. There is no path by which delegation expands authority.

**Why:** otherwise the agent runtime becomes a universal privilege-escalation device.

### INV-17 — No implicit trust between services
Every internal call is authenticated and authorized on its own merits. Network position is not a credential.

### INV-18 — Secrets never leave the vault in plaintext form that can be logged
Credentials are envelope-encrypted at rest, decrypted only in memory at point of use, and are excluded from
logs, traces, error reports, events, and any prompt sent to a model provider.
**Enforcement:** redaction filter at the logging and telemetry boundary + a test that asserts known secret
patterns never appear in emitted telemetry.

---

## Part V — AI safety

### INV-19 — Model output is data, never instruction
Text produced by a model, retrieved from a document, or returned by a tool is untrusted content. It is never
concatenated into a position where it can alter the platform's system policy, and it never directly determines
authorization.

**Why:** this is the *structural* defense against prompt injection. Filtering for "ignore previous
instructions" is a losing arms race; architecture is not.
→ [AI security](../08-security/ai-security.md)

### INV-20 — No tool executes without an authorization decision
Every tool call is authorized against the effective permission set (INV-16), with validated arguments, before
execution. The model requesting a tool is a *proposal*, not a decision.

### INV-21 — Every AI action of consequence is auditable
Agent executions record model, version, prompt hash, tool calls with arguments and results, tokens, cost,
latency, confidence, decision, and any policy violation (FR-405). Audit writes are not optional and not
best-effort.

### INV-22 — Every AI execution has hard ceilings
Tokens, cost, wall-clock duration, tool-call count, and recursion depth are enforced by the runtime. An
execution that hits a ceiling terminates deterministically and emits a governance event.

**Why:** an unbounded agent is an unbounded invoice and an unbounded blast radius.

---

## Part VI — Observability & operations

### INV-23 — Every significant operation is traceable end to end
`trace_id`, `span_id`, and `correlation_id` propagate across HTTP, the outbox, the backbone, workers, agent
calls, and WebSocket pushes. An async hop that drops trace context is a defect.

### INV-24 — Every alert has a runbook
An alert that cannot be acted upon is deleted or fixed, not tolerated.

### INV-25 — Significant architectural decisions have an ADR, written before implementation
"Significant" = affects a boundary, a durability guarantee, a security property, a public contract, or a
vendor dependency.
**Enforcement:** review checklist + `docs-lint` verifying that every ADR references real components and files.

### INV-26 — Documentation is part of the change
A change that alters behavior described in `/docs` updates `/docs` in the same pull request. CI fails on broken
links, dangling references, undocumented tables, undocumented events, and undocumented services.
**Enforcement:** [`tools/docs-lint`](../../tools/docs-lint/README.md).

---

## Enforcement summary

| Invariant | Enforced by | Type |
|-----------|------------|------|
| INV-01, INV-02 | `tools/boundary-check` | Automated, blocking |
| INV-04 | `Nexus::Events::Publisher` runtime guard + lint | Automated, blocking |
| INV-05 | Base consumer requires dedup key | Runtime, blocking |
| INV-07 | Chaos test in CI | Automated, blocking |
| INV-10 | Event schema compatibility check | Automated, blocking |
| INV-11 | Migration linter | Automated, blocking |
| INV-13, INV-14 | Schema conformance + isolation suite | Automated, blocking |
| INV-15, INV-16, INV-20 | Authorization test suite; undeclared-action test | Automated, blocking |
| INV-18 | Telemetry redaction test | Automated, blocking |
| INV-21, INV-22 | Runtime guards + governance tests | Automated, blocking |
| INV-23 | Trace-continuity test | Automated, blocking |
| INV-26 | `tools/docs-lint` | Automated, blocking |
| INV-03, INV-06, INV-08, INV-09, INV-12, INV-17, INV-19, INV-24, INV-25 | Review checklist + targeted tests | Human + partial automation |

Invariants in the bottom row are the ones most at risk of erosion, precisely because they are hardest to
automate. They are re-audited every phase; see [project-state.md](../00-start-here/project-state.md).

---

## Amendments

An invariant may be changed only by:

1. Opening a superseding **ADR** that names the invariant, states why it is now wrong or too costly, and
   analyzes what previously depended on it.
2. Updating this document, incrementing its version, and adding an entry to the
   [architecture changelog](../architecture-changelog.md).
3. Updating every dependent document, diagram, and enforcement mechanism **in the same change**.

Invariants are never silently relaxed. If an invariant is being violated in practice, that is either a bug to
fix or an amendment to argue — it is recorded in [technical-debt.md](../technical-debt.md) until resolved.

### Amendment log

| Version | Date | Change | ADR |
|---------|------|--------|-----|
| 1.0 | 2026-08-09 | Initial ratification | [ADR-001](../11-decisions/ADR-001-architecture-style.md) |
