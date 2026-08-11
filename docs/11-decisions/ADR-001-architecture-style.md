# ADR-001 — Architecture Style: Modular Monolith with Independently Scaled Process Roles

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-09 |
| **Deciders** | Principal Architect, Staff Distributed Systems, SRE |
| **Supersedes** | — |
| **Superseded by** | — |

---

## Context

Aegis Nexus spans eleven bounded contexts ([context map](../02-architecture/context-map.md)) with wildly
different runtime characteristics:

- **Webhook ingestion** — extreme request rate, trivial work per request, must never be slow (NFR-106).
- **Workflow runtime** — long-lived, stateful, crash-sensitive, bursty (NFR-105).
- **Agent runtime** — high latency (seconds), expensive per call, dominated by waiting on model providers.
- **Document ingestion** — CPU- and memory-heavy, batchy, tolerant of minutes of delay.
- **API serving** — latency-sensitive, memory-light (NFR-101/102).

These need to scale *independently*. That requirement is frequently mistaken for a requirement to build
microservices. It is not: it is a requirement for independent **deployment units at runtime**, which is
satisfied by running one image under multiple roles.

Meanwhile the correctness requirements pull hard in the opposite direction. The transactional outbox (INV-04)
requires that domain state and its event publication commit atomically — trivial with one database, and a
distributed-transaction problem the moment contexts own separate databases. Workflow runs coordinate steps
across five contexts; every context boundary crossed synchronously is an availability multiplier.

The team is one engineering organization, not eleven. Splitting into eleven services on day one buys
organizational independence nobody needs yet and pays for it with distributed debugging, N deployment
pipelines, schema-coupled RPC contracts, and a per-request failure probability that compounds.

## Requirements driving this decision

FR-101, FR-102 (isolation must hold across all data access) · FR-204 (transactional outbox) ·
FR-301 (durable execution) · NFR-401 (horizontal scaling of every tier) · NFR-403 (per-tenant work isolation) ·
NFR-505 (module boundaries mechanically enforced) · NFR-206 (zero-downtime rolling deploys).

## Considered alternatives

### A. Microservices from day one — one service per bounded context

**Advantages**
- Hard isolation of failures and resource consumption between contexts.
- Independent release cadence and technology choice per context.
- Team ownership boundaries map cleanly to deployment boundaries.
- Forces contract discipline, because violating it is *impossible* rather than merely forbidden.

**Disadvantages**
- The outbox pattern must be re-implemented per service; cross-context consistency becomes a saga even for
  trivially related writes (e.g. "create org and its first membership").
- Every cross-context read becomes an RPC: added latency, added failure mode, added timeout tuning, added
  circuit breaker. UC-01 crosses five contexts; at 99.9% per service, five sequential dependencies yield
  ~99.5% for the composite path *before* considering retries.
- Local development requires orchestrating 11 services; the feedback loop degrades from seconds to minutes.
- Debugging a workflow run means correlating logs across 11 services from day one, with the tracing
  infrastructure necessarily built *before* the product works.
- Schema evolution becomes an N-party negotiation.

### B. Single-process monolith (one deployable, one runtime)

**Advantages**
- Simplest possible operational model and development loop.
- Trivial transactional consistency.

**Disadvantages**
- Violates the core requirement: a burst of document ingestion would consume the memory and CPU that the
  latency-critical API path needs. NFR-101 and NFR-403 become unachievable.
- One poison workload takes down everything.

### C. Modular monolith with independently scaled process roles *(chosen)*

One codebase and one container image. Internal module boundaries enforced by tooling (INV-01, INV-02). The
image is deployed under distinct **roles** — `api`, `worker:default`, `worker:agents`, `worker:documents`,
`relay`, `projector`, `consumer`, `scheduler` — each with its own replica count, resource limits, queues, and
autoscaling policy.

**Advantages**
- Independent scaling and resource isolation per workload, which was the actual requirement.
- Atomic outbox writes remain trivial (INV-04) because contexts share a database *instance* while remaining
  forbidden from sharing *tables* (INV-01).
- One deployment pipeline, one dependency set, one local `bin/dev`.
- Refactoring across boundaries is a compile-time-visible change, not a multi-repo migration.
- Preserves optionality: because INV-01/INV-02 forbid cross-context table access and cross-context calls go
  through published contracts, extracting a context later is a mechanical change, not a rewrite.

**Disadvantages**
- Boundaries are enforced by *tooling and discipline*, not by the network. Tooling can be bypassed; a
  determined engineer under deadline pressure will find `ActiveRecord::Base.connection.execute`.
- A memory leak or runaway in shared library code affects all roles.
- One language and one runtime for all contexts (no "use Rust for the embedding hot loop" without extraction).
- Blast radius of a bad deploy spans all contexts unless roles are deployed in stages.

### D. Hybrid — monolith plus a small number of extracted edge services

Considered and *partially adopted for later phases*: the webhook ingestion edge and the document-parsing
sandbox are the two components whose characteristics (extreme request rate with near-zero logic; untrusted
file parsing that we want in a hostile-input sandbox) genuinely justify extraction. See "Consequences" below.

## Decision

**Adopt (C), the modular monolith with independently scaled process roles**, with two pre-authorized
extraction candidates (ingestion edge, document parsing sandbox) that may be split out when measured evidence
justifies it.

## Why

The decision reduces to which risk is larger *for this system at this stage*:

| Risk | Microservices (A) | Modular monolith (C) |
|------|------------------|---------------------|
| Getting distributed correctness wrong | **High** — every write is potentially a saga | Low — one transaction boundary |
| Boundary erosion over time | Low | **Medium** — mitigated by CI enforcement |
| Operational complexity now | **High** | Low |
| Cost of being wrong | High — consolidation is very hard | **Low — extraction is mechanical if INV-01/02 hold** |

The asymmetry in the last row is decisive. Choosing (A) and being wrong means merging services, which nobody
ever successfully does. Choosing (C) and being wrong means extracting a context that already communicates only
via published contracts — the exact refactor the boundaries were designed to enable.

The correctness argument is equally decisive: this platform's central promise is durable, non-lossy,
non-duplicating execution. Option (A) forces us to solve distributed consistency *everywhere* in order to gain
organizational independence we do not currently need.

## Consequences

**Immediate**
- `apps/control-plane` is the single Rails codebase; contexts live under `domains/<context>/`.
- Every context exposes a public surface at its top level and hides everything under `internal/`.
- A CI boundary check (`tools/boundary-check`) fails the build on cross-context table or `internal/` access.
- Deployment produces one image, N Kubernetes Deployments differing by command and resources.

**Ongoing obligations**
- Boundary violations must be treated as build failures, not warnings. The moment they become warnings, this
  ADR's central assumption is void and (A) becomes correct by default.
- Any context whose scaling profile diverges enough to need separate limits gets its own worker role, not its
  own service — until measurement proves otherwise.

**Extraction triggers** (any one justifies revisiting):
1. A context needs a different runtime/language for a measured, order-of-magnitude reason.
2. A context's release cadence is blocked by unrelated changes more than ~monthly.
3. A context's resource profile cannot be isolated by role separation alone.
4. Team topology genuinely splits with independent on-call.

## Failure modes

| Failure mode | Detection | Mitigation |
|--------------|-----------|------------|
| Boundary erosion (cross-context queries creep in) | `boundary-check` in CI; quarterly boundary audit | Blocking check; violations are build failures |
| One role's bug crashes shared code and thus all roles | Per-role error rate + crash-loop alerts | Staged role rollout (`worker` roles before `api`); per-role circuit breakers |
| Shared DB connection exhaustion — a burst in one role starves another | Connection-pool saturation metric per role | Separate pooler pools and per-role `max_connections` budgets (see [ADR-002](ADR-002-database.md)) |
| Deploy blast radius spans all contexts | Canary + smoke tests | Canary the `api` role first; workers drain and resume from durable state (INV-07) |
| Monolith build/test time grows until velocity collapses | CI duration trend | Parallel test partitions by context; test selection by changed domain |

## Operational impact

- **Simplifies:** one pipeline, one image, one set of migrations, one local dev command, one place to look first.
- **Complicates:** role-aware deployment ordering; per-role resource tuning; noisy-neighbor management inside a
  shared process for CPU-bound work.
- Runbooks are per-role, not per-service: [deployment](../12-operations/deployment.md).

## Cost impact

Materially cheaper than (A) at this stage: no per-service baseline replicas (11 services × 2 replicas minimum
would be ~22 always-on pods before any load), one observability pipeline, one CI pipeline. The saving is
largely fixed-cost, so it shrinks in relative terms as scale grows — which is consistent with revisiting this
ADR at scale, not at inception.

## Security impact

- **Negative:** a single process boundary means a code-execution vulnerability in any context has the
  privileges of the whole application. Compensated by INV-14/INV-15 (isolation and authorization are enforced
  in the database and the evaluator, not by module separation) and by extracting the *hostile-input* path
  (document parsing) where the risk is concentrated.
- **Positive:** one authentication/authorization implementation instead of eleven; far fewer places to get
  tenant scoping wrong; no internal RPC surface to secure on day one.

## Scalability impact

Scales horizontally per role. The limits that will bite first are **shared PostgreSQL** (addressed in
[ADR-002](ADR-002-database.md) and [ADR-009](ADR-009-multi-tenancy.md) via partitioning, read replicas, and the
dedicated-tenant tier) and **connection count**, not the process model. See
[capacity planning](../10-performance/capacity-planning.md).

## Related decisions

- [ADR-002 — Database](ADR-002-database.md) (shared instance assumption originates here)
- [ADR-003 — Event backbone](ADR-003-event-bus.md) (in-process contexts still communicate via events)
- [ADR-009 — Multi-tenancy](ADR-009-multi-tenancy.md) (dedicated tier reuses the same image)
- Constitution: [INV-01](../02-architecture/architecture-constitution.md#inv-01--a-bounded-context-owns-its-tables-exclusively),
  [INV-02](../02-architecture/architecture-constitution.md#inv-02--the-published-contract-is-the-only-public-surface),
  [INV-03](../02-architecture/architecture-constitution.md#inv-03--contexts-communicate-asynchronously-by-default)

## Related code

- `apps/control-plane/domains/` — one directory per bounded context
- `apps/control-plane/config/roles.yml` — role → queues/concurrency mapping
- `tools/boundary-check/` — the enforcement mechanism this ADR depends on

## Related diagrams

- [Container diagram](../02-architecture/container-diagram.md)
- [Component diagram](../02-architecture/component-diagram.md)
- [Deployment architecture](../02-architecture/deployment-architecture.md)
