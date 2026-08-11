# Requirements Register

> Every requirement has a stable ID. IDs are referenced by ADRs, code annotations, tests, and the
> [traceability matrix](../traceability-matrix.md). **Never renumber a requirement** — supersede it instead.
>
> Status values: `accepted` (agreed, not yet built) · `building` · `implemented` · `deferred` · `superseded`

---

## Reading key

| Field | Meaning |
|-------|---------|
| **Persona** | Who this exists for ([personas](personas.md)). A requirement with no persona is not built. |
| **Rationale** | *Why*, not *what*. This is the field that survives when the implementation changes. |
| **Verified by** | The test or artifact that proves the requirement holds. |

---

## FR-1xx — Identity, tenancy, authorization

<a id="fr-101"></a>
### FR-101 — Tenant as the root isolation unit
**Persona:** P-4 · **Status:** accepted
Every persisted row, cache key, search document, vector, queue message, and log line that carries business data
MUST be attributable to exactly one organization (tenant), except explicitly enumerated platform-global tables.
**Rationale:** Isolation cannot be added later; retrofitting a tenant column onto a mature schema is a multi-quarter
migration with a breach-shaped failure mode in the middle.
**Verified by:** schema conformance test (every table either has `organization_id` or is on the global allow-list).

<a id="fr-102"></a>
### FR-102 — Defense-in-depth tenant isolation
**Persona:** P-4 · **Status:** accepted
Isolation MUST be enforced at ≥3 independent layers: (a) PostgreSQL Row-Level Security, (b) application query
scoping, (c) request-scoped tenant context that fails closed when absent.
**Rationale:** Single-layer isolation fails to a single bug. See [ADR-009](../11-decisions/ADR-009-multi-tenancy.md).
**Verified by:** isolation test suite that attempts cross-tenant reads at each layer with the others disabled.

<a id="fr-103"></a>
### FR-103 — Tenancy model supports 1 → 10⁵ tenants plus dedicated enterprise tenants
**Persona:** P-4, P-5 · **Status:** accepted
**Rationale:** The cost model of a shared pool and the isolation demands of a regulated enterprise are
irreconcilable in one topology. See [ADR-009](../11-decisions/ADR-009-multi-tenancy.md).

<a id="fr-104"></a>
### FR-104 — Tenant promotion path (shared → dedicated) without data loss or extended downtime
**Persona:** P-4 · **Status:** accepted
Target: < 15 min write-freeze for a 500 GB tenant.
**Verified by:** documented + rehearsed procedure in [tenant-migration runbook](../12-operations/runbooks/tenant-promotion.md).

<a id="fr-105"></a>
### FR-105 — Human authentication: password + TOTP MFA, OIDC/SAML SSO for enterprise
**Persona:** P-1, P-4 · **Status:** accepted

<a id="fr-106"></a>
### FR-106 — Non-human identity for services and agents
**Persona:** P-6, P-3 · **Status:** accepted
Services and agents are first-class principals with their own credentials, scopes, and audit identity.
**Rationale:** "The app did it" is not an acceptable audit answer, and shared service accounts make least
privilege impossible.

<a id="fr-107"></a>
### FR-107 — RBAC with ABAC overlay
**Persona:** P-1, P-4 · **Status:** accepted
Coarse role grants, refined by attribute-based conditions (resource owner, environment, data classification,
time, risk tier).
**Rationale:** Pure RBAC produces role explosion; pure ABAC is unreviewable by non-engineers.

<a id="fr-108"></a>
### FR-108 — Deny-by-default authorization, centrally evaluated
**Persona:** P-4 · **Status:** accepted
Absence of an explicit grant is a denial. Authorization decisions are made by one evaluator, not scattered
`if current_user.admin?` checks.
**Verified by:** every controller action must declare an authorization; a test asserts no undeclared actions exist.

<a id="fr-109"></a>
### FR-109 — Short-lived tokens with explicit audience and scope
**Persona:** P-4 · **Status:** accepted
Access tokens ≤ 15 min; refresh rotation with reuse detection.

---

## FR-2xx — Events, ingestion, backbone

<a id="fr-201"></a>
### FR-201 — Signed webhook ingestion with replay protection
**Persona:** P-2 · **Status:** accepted
HMAC (or provider-specific) signature verification, timestamp freshness window, constant-time comparison,
nonce/idempotency-key dedup.
**Verified by:** forged / replayed / expired / malformed webhook test cases.

<a id="fr-202"></a>
### FR-202 — Ingestion is durable before it is processed
**Persona:** P-1, P-3 · **Status:** accepted
The HTTP 2xx returned to a provider means "we have durably stored this", never "we have processed this".
**Rationale:** Coupling the provider's request lifecycle to our downstream processing makes their timeout our
availability problem, and their retry our duplicate problem.

<a id="fr-203"></a>
### FR-203 — At-least-once delivery with idempotent consumers
**Persona:** P-3 · **Status:** accepted
The platform MUST NOT claim exactly-once *delivery*. It MUST provide effectively-once *processing* via
consumer-side dedup + idempotent handlers. See [idempotency](../04-distributed-systems/idempotency.md).

<a id="fr-204"></a>
### FR-204 — Transactional outbox
**Persona:** P-3 · **Status:** accepted
No event may be published outside the database transaction that produced the state it describes.
**Rationale:** The classic dual-write failure — commit succeeds, process dies before publish — silently
desynchronizes the entire downstream system. See [ADR-003](../11-decisions/ADR-003-event-bus.md).
**Verified by:** crash-injection test between commit and publish.

<a id="fr-205"></a>
### FR-205 — Per-key ordering guarantee
**Persona:** P-2 · **Status:** accepted
Events sharing a partition key (default: aggregate ID) are processed in production order. Global ordering is
explicitly NOT guaranteed. See [ordering guarantees](../04-distributed-systems/ordering-guarantees.md).

<a id="fr-206"></a>
### FR-206 — Dead-letter handling with operator replay
**Persona:** P-3 · **Status:** accepted
Poison messages are quarantined with full context after bounded retries, and are replayable after a fix.

<a id="fr-207"></a>
### FR-207 — Versioned event schemas with compatibility enforcement
**Persona:** P-2, P-3 · **Status:** accepted
Every event type carries a version; schema changes are validated for backward compatibility in CI.
**Verified by:** schema-compatibility CI check against the registered baseline.

<a id="fr-208"></a>
### FR-208 — Event replay to rebuild any projection
**Persona:** P-3 · **Status:** accepted
Any read model MUST be reconstructable from the event log without vendor assistance.

<a id="fr-209"></a>
### FR-209 — Correlation and causation IDs on every event
**Persona:** P-3 · **Status:** accepted
`correlation_id` (the originating business interaction) and `causation_id` (the immediate parent message)
propagate through every hop, sync and async.

---

## FR-3xx — Workflows

<a id="fr-301"></a>
### FR-301 — Durable execution surviving crash, restart, and deploy
**Persona:** P-1, P-2 · **Status:** accepted
Workflow state lives in PostgreSQL, never in process memory. Recovery MUST complete < 30 s after worker loss.
**Verified by:** chaos scenario `worker-kill-mid-step`.

<a id="fr-302"></a>
### FR-302 — Step types: sequential, branch, condition, loop, parallel, wait, timer, approval, HTTP, code, agent
**Persona:** P-2 · **Status:** accepted

<a id="fr-303"></a>
### FR-303 — Retries with exponential backoff + jitter, and per-step timeouts
**Persona:** P-2 · **Status:** accepted

<a id="fr-304"></a>
### FR-304 — Long waits (days–weeks) without holding resources
**Persona:** P-1 · **Status:** accepted
A workflow waiting on approval or a timer MUST consume no worker, no thread, and no connection.

<a id="fr-305"></a>
### FR-305 — Workflow versioning with in-flight compatibility
**Persona:** P-2 · **Status:** accepted
Runs are pinned to the definition version they started on. Changing a definition MUST NOT corrupt in-flight runs.
**Rationale:** This is the single most common source of data corruption in homegrown workflow engines.

<a id="fr-306"></a>
### FR-306 — Compensation (saga) for partially completed multi-system operations
**Persona:** P-1 · **Status:** accepted

<a id="fr-307"></a>
### FR-307 — Runaway protection: max duration, max steps, max depth, cost ceiling
**Persona:** P-5 · **Status:** accepted
A run that violates any ceiling terminates itself and emits a governance event.

<a id="fr-308"></a>
### FR-308 — Complete per-run execution timeline
**Persona:** P-1, P-2, P-3 · **Status:** accepted
Every step attempt, input, output, error, retry, and timing is queryable.

<a id="fr-309"></a>
### FR-309 — Idempotent step execution
**Persona:** P-3 · **Status:** accepted
Re-executing a step after a crash MUST NOT duplicate its external effects.

<a id="fr-310"></a>
### FR-310 — Dry-run / simulation mode
**Persona:** P-2 · **Status:** accepted
Execute a definition against sample input with all external effects stubbed.

---

## FR-4xx — AI agents, tools, governance

<a id="fr-401"></a>
### FR-401 — Agents are principals with identity, tenant, and explicit configuration
**Persona:** P-6, P-4 · **Status:** accepted

<a id="fr-402"></a>
### FR-402 — Tool registry with schema, permissions, validation, timeout, rate limit, risk tier
**Persona:** P-4 · **Status:** accepted

<a id="fr-403"></a>
### FR-403 — Agent permissions are a strict subset of the invoking principal's
**Persona:** P-4 · **Status:** accepted
An agent can never be a privilege-escalation vector. Delegation narrows; it never widens.
**Verified by:** authorization test asserting `agent_permissions ⊆ invoker_permissions` for every invocation path.

<a id="fr-404"></a>
### FR-404 — Model output is never trusted as instruction
**Persona:** P-4, P-6 · **Status:** accepted
Retrieved documents, tool results, and model text are data. Only the platform's own system policy is instruction.
**Rationale:** This is the structural defense against indirect prompt injection; string-level filtering is not.

<a id="fr-405"></a>
### FR-405 — Complete AI execution record
**Persona:** P-4, P-5 · **Status:** accepted
Records agent, tenant, user, execution, workflow, model + version, prompt hash, every tool call with arguments
and results, tokens, latency, cost, confidence, decision, escalation, and policy violations.

<a id="fr-406"></a>
### FR-406 — Hard ceilings per execution: tokens, cost, wall-clock, tool calls, recursion depth
**Persona:** P-5 · **Status:** accepted
Ceilings are enforced by the runtime, not requested of the model.

<a id="fr-407"></a>
### FR-407 — Human-in-the-loop policies with durable, replay-resistant approvals
**Persona:** P-1, P-4 · **Status:** accepted
Policy examples: amount > threshold → approve; confidence < threshold → escalate; tool risk = HIGH → approve.
Approval tokens are single-use, bound to the run + step + approver, and expire.

<a id="fr-408"></a>
### FR-408 — Specialist agents: operations, financial, support, security, data, orchestrator
**Persona:** P-1, P-4, P-5 · **Status:** accepted

<a id="fr-409"></a>
### FR-409 — Model routing across cost/capability tiers with provider fallback
**Persona:** P-5 · **Status:** accepted
Routing inputs: task complexity, tenant budget, latency target, accuracy need, privacy policy, availability.
Behavior when all providers fail MUST be defined, not emergent.

<a id="fr-410"></a>
### FR-410 — Three-tier agent memory (short-term, episodic, semantic) with tenant isolation
**Persona:** P-6 · **Status:** accepted

---

## FR-5xx — Documents, knowledge, search

<a id="fr-501"></a>
### FR-501 — Asynchronous document ingestion pipeline
**Persona:** P-1 · **Status:** accepted
Upload → scan → metadata → parse → normalize → chunk → embed → index → validate → available.
Each stage independently retryable; failures visible per document.

<a id="fr-502"></a>
### FR-502 — Hybrid retrieval (keyword + vector) with reranking and citations
**Persona:** P-1 · **Status:** accepted
Every generated claim that draws on retrieved content carries a resolvable source citation.

<a id="fr-503"></a>
### FR-503 — Retrieval is tenant-scoped at the storage layer, not the query layer alone
**Persona:** P-4 · **Status:** accepted
**Rationale:** A forgotten filter in one of dozens of query sites is inevitable; the store itself must refuse.

<a id="fr-504"></a>
### FR-504 — Malicious document defenses
**Persona:** P-4 · **Status:** accepted
Malware scanning, structural sanitization, hidden-instruction detection, and untrusted-content framing at
prompt-assembly time.

<a id="fr-505"></a>
### FR-505 — Enterprise search across tasks, events, documents, audit, workflows, memories
**Persona:** P-1 · **Status:** accepted
With filters, facets, keyword, semantic, and hybrid modes — all tenant-scoped and permission-filtered.

---

## FR-6xx — Integrations

<a id="fr-601"></a>
### FR-601 — Integration catalog with typed connectors
**Persona:** P-2 · **Status:** accepted

<a id="fr-602"></a>
### FR-602 — Credentials encrypted at rest with envelope encryption and rotation
**Persona:** P-4 · **Status:** accepted
Plaintext credentials never appear in logs, traces, error messages, events, or agent context.

<a id="fr-603"></a>
### FR-603 — Outbound delivery with retries, backoff, circuit breaking, and endpoint health
**Persona:** P-2, P-3 · **Status:** accepted
A customer endpoint returning 500 for hours MUST NOT degrade the platform for other tenants.

<a id="fr-604"></a>
### FR-604 — Per-tenant, per-integration rate limiting and concurrency caps
**Persona:** P-3 · **Status:** accepted
Noisy-neighbor containment.

---

## FR-7xx — Billing, cost, FinOps

<a id="fr-701"></a>
### FR-701 — Cost attribution to tenant, user, workflow, run, agent, execution, and integration
**Persona:** P-5 · **Status:** accepted

<a id="fr-702"></a>
### FR-702 — Hierarchical budgets with hard enforcement
**Persona:** P-5 · **Status:** accepted
Tenant → agent → workflow → user. Exceeding a budget blocks *new* spend; it does not corrupt in-flight state.

<a id="fr-703"></a>
### FR-703 — Usage metering: input/output/cached tokens, embeddings, external API calls, storage, compute
**Persona:** P-5 · **Status:** accepted

<a id="fr-704"></a>
### FR-704 — Cost anomaly detection with automated investigation
**Persona:** P-5 · **Status:** accepted

---

## FR-8xx — Audit & observability

<a id="fr-801"></a>
### FR-801 — Immutable, tamper-evident audit trail
**Persona:** P-4 · **Status:** accepted
Append-only, hash-chained per tenant, independently verifiable, retained per policy.

<a id="fr-802"></a>
### FR-802 — Every state-changing API call is audited with actor, action, resource, before/after, and outcome
**Persona:** P-4 · **Status:** accepted

<a id="fr-803"></a>
### FR-803 — Distributed tracing across sync and async boundaries
**Persona:** P-3 · **Status:** accepted
A trace initiated by an HTTP request MUST continue through the outbox, the backbone, the worker, the agent
call, and the WebSocket push.

<a id="fr-804"></a>
### FR-804 — Real-time updates to the UI
**Persona:** P-1 · **Status:** accepted

---

## FR-9xx — Frontend

<a id="fr-901"></a>
### FR-901 — Command center (operational overview)
**Persona:** P-1 · **Status:** accepted
<a id="fr-902"></a>
### FR-902 — Organization, user, role management
**Persona:** P-1, P-4 · **Status:** accepted
<a id="fr-903"></a>
### FR-903 — Visual workflow builder (nodes + edges) with validation
**Persona:** P-2 · **Status:** accepted
<a id="fr-904"></a>
### FR-904 — Run viewer, agent console + timeline, event explorer, audit explorer, cost + observability dashboards
**Persona:** P-1..P-5 · **Status:** accepted
<a id="fr-905"></a>
### FR-905 — Permission-aware UI with real-time updates, optimistic writes where safe, and explicit error/loading states
**Persona:** P-1 · **Status:** accepted
**Note:** the UI hides what a user may not do, but hiding is *never* the enforcement mechanism.

---

## NFR-1xx — Performance

| ID | Requirement | Value | Notes |
|----|-------------|-------|-------|
| **<a id="nfr-101"></a>NFR-101** | API latency p95 | < 150 ms | Excludes deliberately long-running endpoints |
| **<a id="nfr-102"></a>NFR-102** | API latency p99 | < 500 ms | |
| **<a id="nfr-103"></a>NFR-103** | Event ingestion → first consumer | < 1 s p95 | Measured end to end |
| **<a id="nfr-104"></a>NFR-104** | WebSocket update latency | < 200 ms p95 | From projection commit to client |
| **<a id="nfr-105"></a>NFR-105** | Workflow recovery after worker loss | < 30 s | Lease expiry + reclaim |
| **<a id="nfr-106"></a>NFR-106** | Webhook ingest endpoint | < 50 ms p95 | Store-and-ack only |

Derivations, formulas, and the capacity model: [performance model](../10-performance/performance-model.md).

## NFR-2xx — Availability & recovery

| ID | Requirement | Value |
|----|-------------|-------|
| **<a id="nfr-201"></a>NFR-201** | Control-plane availability SLO | 99.9 % monthly |
| **<a id="nfr-202"></a>NFR-202** | Event ingestion availability SLO | 99.95 % monthly |
| **<a id="nfr-203"></a>NFR-203** | RPO | < 5 min |
| **<a id="nfr-204"></a>NFR-204** | RTO | < 15 min |
| **<a id="nfr-205"></a>NFR-205** | Restore rehearsal cadence | Monthly, automated, alerting on failure |
| **<a id="nfr-206"></a>NFR-206** | Zero-downtime rolling deploys | Required; N and N+1 must interoperate |

## NFR-3xx — Security

| ID | Requirement |
|----|-------------|
| **<a id="nfr-301"></a>NFR-301** | Encryption in transit (TLS 1.3) and at rest (AES-256) everywhere |
| **<a id="nfr-302"></a>NFR-302** | Least privilege for every principal, human or not |
| **<a id="nfr-303"></a>NFR-303** | No implicit trust between internal services (zero trust) |
| **<a id="nfr-304"></a>NFR-304** | Secrets never in source, images, env dumps, logs, or traces |
| **<a id="nfr-305"></a>NFR-305** | All security findings tracked to closure with a regression test ([findings register](../security/findings.md)) |

## NFR-4xx — Scalability

| ID | Requirement |
|----|-------------|
| **<a id="nfr-401"></a>NFR-401** | Horizontal scaling of every stateless tier |
| **<a id="nfr-402"></a>NFR-402** | No global lock, global counter, or global sequence on the hot path |
| **<a id="nfr-403"></a>NFR-403** | Per-tenant work isolation such that one tenant cannot starve others |
| **<a id="nfr-404"></a>NFR-404** | Data model viable to 10⁹ rows in the largest tables with a documented path beyond |

## NFR-5xx — Operability & maintainability

| ID | Requirement |
|----|-------------|
| **<a id="nfr-501"></a>NFR-501** | Every request and async execution carries trace, span, and correlation IDs |
| **<a id="nfr-502"></a>NFR-502** | Every alert links to a runbook |
| **<a id="nfr-503"></a>NFR-503** | Documentation consistency is CI-enforced ([docs-lint](../../tools/docs-lint/README.md)) |
| **<a id="nfr-504"></a>NFR-504** | Every architectural decision of significant impact has an ADR |
| **<a id="nfr-505"></a>NFR-505** | Module boundaries are mechanically enforced, not merely documented |

## NFR-6xx — Compliance & residency

| ID | Requirement |
|----|-------------|
| **<a id="nfr-601"></a>NFR-601** | Tenant data residency pinning (BR / US / EU / APAC) |
| **<a id="nfr-602"></a>NFR-602** | Right-to-erasure workflow compatible with an append-only event log ([data retention](../06-data/data-retention.md)) |
| **<a id="nfr-603"></a>NFR-603** | Exportable, verifiable audit evidence per tenant |

---

## Open questions

Tracked in [project-state.md](../00-start-here/project-state.md#unresolved-questions) so they are never lost
across a context boundary.
