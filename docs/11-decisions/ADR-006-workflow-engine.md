# ADR-006 — Build the Workflow Engine (Rather Than Adopt Temporal)

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-09 |
| **Deciders** | Principal Architect, Staff Distributed Systems, Product |
| **Supersedes** | — |

---

## Context

This is the highest-risk decision in the system, and the one most likely to be judged wrong later. It deserves
the most honest treatment.

Aegis Nexus needs durable execution: runs that survive crashes and deploys, sleep for weeks, retry with
backoff, wait for human approval, and compensate on failure (FR-301..310). Temporal, Cadence, and AWS Step
Functions solve exactly this, and solve it well. Building a workflow engine is a well-known way to spend two
years reinventing something worse.

However, our workflows differ from the case those tools are optimized for in ways that turn out to matter:

| Dimension | Temporal's model | Aegis Nexus's need |
|-----------|-----------------|--------------------|
| **What a workflow is** | Code, written by engineers, deployed with the app | **Data**, authored by non-engineers in a visual builder (FR-903), stored per tenant, changed without a deploy |
| **Who authors it** | The engineering team | Thousands of tenants' own automation engineers (P-2) |
| **Determinism model** | Replay of workflow *code*; changing code breaks in-flight runs unless versioned via SDK APIs | Definitions are versioned rows; runs pin to a version (FR-305, INV-12) |
| **Governance** | Orthogonal to the engine | Budget ceilings, tool permissions, approval policy, and cost metering must be enforced *inside* step execution (FR-307, FR-702, INV-22) |
| **Introspection** | Via Temporal's own UI/API | The run timeline is a **product feature** (FR-308), queried with tenant-scoped SQL and joined to agent executions, costs, and audit |
| **Tenancy** | Namespaces; heavy per-namespace overhead at 10⁵ tenants | 10⁵ tenants in one deployment (FR-103) |

The decisive point is the first row. Temporal's core abstraction is *durable code*. Ours must be *durable
interpretation of user-authored data*. We would end up writing a single Temporal workflow whose body is an
interpreter for our definition format — at which point Temporal provides the durability primitives (which we
would still have to wrap for governance) while we still write the interpreter, the versioning model, the step
registry, and the timeline. The leverage is much smaller than it first appears.

## Requirements driving this decision

FR-301 (crash-durable), FR-302 (step types), FR-303 (retry/backoff/timeout), FR-304 (long waits with no held
resources), FR-305 (version pinning), FR-306 (compensation), FR-307 (runaway ceilings), FR-308 (timeline),
FR-309 (idempotent steps), FR-310 (dry run) · FR-103 (10⁵ tenants) · INV-07, INV-12, INV-22.

## Considered alternatives

### A. Temporal (self-hosted or Cloud)

**Advantages**
- Battle-tested durable execution; the hard parts (history, replay, timers, heartbeats, task queues,
  visibility) are solved and operated by people who specialize in it.
- Excellent primitives for exactly our failure model: worker crash, long sleeps, activity retries.
- Mature tooling, SDKs, and a large operational corpus.
- We would not have to write, test, and own the crash-recovery core — the part most likely to have subtle bugs.

**Disadvantages**
- Our definitions are data, not code (above). The impedance mismatch pushes us toward "one interpreter
  workflow", which forfeits most of Temporal's ergonomic value while keeping its operational cost.
- Determinism constraints apply to the *interpreter*; a bug fix in the interpreter can break in-flight runs
  unless carefully versioned — a subtler and more dangerous version of the problem we already have to solve.
- 10⁵ tenants map poorly onto namespaces; a single namespace loses per-tenant isolation and quota control.
- Governance (budget, permissions, approvals) sits outside its model, so every activity gets wrapped anyway.
- Run history lives in Temporal's store, not ours — so FR-308's product-grade timeline (joined with agent
  executions, cost, and audit, tenant-scoped, searchable) requires exporting and re-modeling it. We now have
  two sources of truth for run state, which contradicts INV-04's spirit.
- Substantial operational addition: Temporal cluster (or vendor dependency), its own DB, its own scaling and
  failure modes, its own DR story that must independently meet NFR-203/204.

### B. AWS Step Functions
**Advantages:** fully managed; JSON-defined state machines are close to our data model.
**Disadvantages:** hard cloud lock-in against a multi-region, multi-cloud-capable design; per-transition
pricing is punitive at our modeled event volumes; execution history limits; weak fit for per-tenant
governance; no self-hosted story for on-prem/dedicated enterprise tenants.

### C. Existing Ruby workflow gems
**Disadvantages:** none in the ecosystem provide crash-durable, version-pinned, leased execution at the
required fidelity. Evaluated and rejected as not meeting FR-301/305.

### D. Build a durable interpreter on PostgreSQL *(chosen)*

Definitions are versioned rows; runs are event-sourced aggregates ([ADR-005](ADR-005-event-sourcing.md));
step execution is driven by leased workers polling a due-time-indexed job queue
([ADR-003](ADR-003-event-bus.md), mechanism 2).

**Advantages**
- Run state lives in *our* database, joined directly to tenants, agents, costs, approvals, and audit.
  FR-308 becomes a query rather than an integration.
- Governance is enforced at the step boundary, in the same transaction as the state transition.
- Version pinning (INV-12) is a foreign key to a `workflow_versions` row — simple, obvious, and inspectable.
- Long waits cost exactly one indexed row and zero workers (FR-304).
- No additional infrastructure; DR and multi-region inherit the database's story.
- Local development and CI run the real engine, enabling the crash/duplicate/delay tests this system needs.

**Disadvantages — stated plainly**
- **We own the correctness of crash recovery.** Lease expiry, at-least-once step execution, and idempotent
  side effects are ours to get right and keep right. This is genuine risk.
- Throughput ceiling is the database's. A DB-backed queue will not match a purpose-built one at extreme scale.
- We must build: timers, backoff, cancellation, compensation, parallel joins, sub-workflows, and the
  visibility layer. That is months of work that Temporal would have given us.
- Team knowledge concentration: the engine becomes a component only a few engineers deeply understand.

## Decision

**Build the durable workflow interpreter on PostgreSQL**, with the following non-negotiable design
constraints (these are what make the risk acceptable):

1. **All run state is durable before a step is attempted** (INV-07). No in-memory continuation, ever.
2. **Workers hold a lease, not a lock.** A lease has an expiry; a crashed worker's run is reclaimable after
   expiry with no human action. Recovery target < 30 s (NFR-105).
3. **Every step attempt is a separate, immutable `step_execution` row.** Retries never mutate history.
4. **Step execution is at-least-once; steps must be idempotent** (FR-309, INV-05). Steps with external side
   effects carry an idempotency key derived from `(run_id, step_id, attempt_of_record)`.
5. **Runs pin to a `workflow_version`** (INV-12). Definition edits create versions; they never mutate.
6. **Ceilings are enforced by the engine**: max duration, max steps, max depth, cost budget (FR-307).
7. **A waiting run holds zero resources**: it is a row with a `wake_at` or an external-signal key.
8. **The engine is exercised by chaos tests in CI**: kill mid-step, duplicate delivery, delayed delivery,
   clock skew, and lease expiry races are regression tests, not manual checks.

### Pre-committed migration trigger

Because this is the riskiest decision, we pre-commit the conditions under which we would migrate to Temporal,
so the choice can be revisited on evidence rather than fatigue:

- Sustained step throughput requirement > ~5,000 steps/sec/region *and* database contention is the proven
  bottleneck after partitioning; **or**
- More than two production incidents in a rolling year whose root cause is a defect in engine crash-recovery
  semantics; **or**
- Median engineering time spent on engine maintenance exceeds ~15 % of platform capacity for two quarters.

The migration path is documented in advance ([architecture change protocol](../02-architecture/architecture-change-protocol.md))
so it is a plan, not a rewrite.

## Why

The product requires that workflows be **tenant-authored data with platform-enforced governance and
first-class introspection**. Every adoption option forces us to build that layer anyway, while adding a second
system of record for run state — the specific thing our Constitution exists to prevent (INV-04's spirit:
one place where truth lives). We accept ownership of crash-recovery correctness in exchange, and we contain
that risk with the eight constraints above plus mandatory chaos testing.

## Consequences

- The engine is the most heavily tested component in the repository, including property-based tests over
  step-transition sequences and fault-injection tests in CI.
- Engine changes require replay-compatibility review against in-flight run states.
- On-call must understand lease semantics; [workflow stuck runbook](../12-operations/runbooks/workflow-stuck.md)
  is mandatory reading.

## Failure modes

| Failure mode | Detection | Impact | Mitigation |
|--------------|-----------|--------|------------|
| Worker crash mid-step | Lease expiry | Step retried | Idempotent steps (FR-309); attempt recorded before external call |
| **Double execution at lease boundary** (worker not actually dead) | Duplicate side-effect detection; fencing-token mismatch | Duplicate external effect | Monotonic **fencing token** per lease; external calls carry idempotency keys; late writes from an expired lease are rejected by version check |
| Clock skew makes leases expire early/late | Clock-skew metric across nodes | Premature reclaim or stuck run | Lease expiry evaluated by the **database's** clock, never the worker's |
| Poison step retried forever | Attempt counter | Wasted cost, stuck run | Bounded retries → run fails with compensation; DLQ for inspection |
| Runaway loop | Step count / duration / cost ceilings | Cost explosion | Hard ceilings terminate the run and emit a governance event (FR-307) |
| Deploy changes a definition mid-run | Version pin | None (by design) | INV-12; tested by an upgrade-during-run test |
| Interpreter bug corrupts run state | Replay-equivalence tests; state-machine invariant checks | Wrong business outcome | Event-sourced runs allow reconstruction and correction via compensating events ([ADR-005](ADR-005-event-sourcing.md)) |
| Timer storm (10⁵ runs wake simultaneously) | Job queue depth spike | Latency for all runs | Jittered wake times; per-tenant dispatch fairness (NFR-403); queue depth autoscaling |
| Long wait exceeds partition retention | Oldest-pending-run monitor | Run cannot resume | Waiting runs live in a non-rotated table; retention policy explicitly excludes active runs |
| DB contention on hot run rows | Lock-wait metrics | Throughput collapse | Hash partitioning by `organization_id`; optimistic concurrency; no `SELECT FOR UPDATE` on the hot path |

## Operational impact

Adds engine-specific runbooks and dashboards (runs by state, lease reclaim rate, step attempt rate, stuck-run
age). Removes a whole external cluster from the DR and multi-region plans.

## Cost impact

Lower infrastructure cost (no Temporal cluster or per-transition vendor pricing) traded for higher engineering
cost. Honest accounting: the engine is a multi-month build and a permanent maintenance obligation. The
migration triggers above exist so that this cost is monitored rather than assumed.

## Security impact

Positive: step execution passes through our authorization and budget enforcement in-process, with no
cross-system trust boundary. Run state, approvals, and audit share one RLS-protected database, so tenant
isolation is enforced once (INV-14) rather than negotiated across systems.

## Scalability impact

Bounded by database write throughput on `step_executions` and by job-queue claim rate. Modeled in
[capacity planning](../10-performance/capacity-planning.md); partitioning and per-tenant fair dispatch are the
scaling levers, and the throughput trigger above defines where the design stops being appropriate.

## Related decisions

[ADR-002](ADR-002-database.md) · [ADR-003](ADR-003-event-bus.md) · [ADR-005](ADR-005-event-sourcing.md) ·
[ADR-007](ADR-007-ai-runtime.md) (agents are a step type) · [ADR-010](ADR-010-consistency-model.md)

## Related code

`apps/control-plane/domains/workflows/` · `domains/workflows/internal/engine/` ·
`infrastructure/jobs/`

## Related diagrams

[Workflow runtime](../03-domains/workflows/runtime.md) ·
[Failure recovery](../04-distributed-systems/failure-recovery.md)
