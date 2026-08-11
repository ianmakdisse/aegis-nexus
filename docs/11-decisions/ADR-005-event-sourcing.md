# ADR-005 — Event Sourcing for Four Aggregates, and Nowhere Else

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-09 |
| **Deciders** | Principal Architect, Database Architect |
| **Supersedes** | — |

---

## Context

Event sourcing stores an aggregate's history as an ordered sequence of immutable events, deriving current
state by folding them. Its benefits are real and specific: perfect audit, temporal queries, the ability to
answer questions you did not know to ask when you wrote the code, and rebuildable read models.

Its costs are equally real and are systematically underestimated:

- **Every schema mistake is permanent.** You cannot migrate history; you can only upcast it forever.
- **Querying current state requires either a projection or a replay.** "Show me all users with role X" is a
  trivial SQL query in a state-stored model and a projection-maintenance problem in an event-sourced one.
- **Deletion becomes hard.** GDPR erasure against an immutable log requires crypto-shredding (NFR-602).
- **Onboarding cost is high.** Every engineer must understand the pattern before touching anything.
- **Snapshotting, upcasting, and concurrency control are infrastructure you must build and test.**

The decision therefore is not "should we use event sourcing" but "**for which aggregates is history itself the
valuable artifact?**"

## Requirements driving this decision

FR-208 (replay) · FR-308 (complete run timeline) · FR-405 (complete AI execution record) ·
FR-801 (immutable, tamper-evident audit) · FR-301/305 (durable, version-pinned execution) ·
NFR-602 (right to erasure).

## The test applied

An aggregate is event-sourced only if **all four** hold:

1. **History is a product requirement**, not just an engineering nicety.
2. **The aggregate has a genuine lifecycle** — a sequence of meaningful state transitions, not just field edits.
3. **Reconstructing past state has business value** (dispute resolution, compliance, debugging correctness).
4. **The write volume per aggregate instance is bounded** (hundreds to thousands of events, not millions).

Applied:

| Aggregate | 1. History required? | 2. Lifecycle? | 3. Past state valuable? | 4. Bounded? | Verdict |
|-----------|:---:|:---:|:---:|:---:|---------|
| **WorkflowRun** | Yes (FR-308) | Yes — rich | Yes (why did this run do that?) | Yes (~10²–10³) | **Event-sourced** |
| **AgentExecution** | Yes (FR-405) | Yes | Yes (compliance, cost disputes) | Yes (~10¹–10²) | **Event-sourced** |
| **ApprovalRequest** | Yes (FR-407) | Yes | Yes (who approved what, when, with what context) | Yes (~10⁰–10¹) | **Event-sourced** |
| **AuditTrail** | Yes (FR-801) | It *is* a log | Yes | Append-only by nature | **Event-sourced** (degenerate — log only, no fold) |
| User / Organization | Change log needed, full history not | Weak | Rarely | Yes | State-stored + audit log |
| Role / Permission grant | Audit needed | Weak | Occasionally | Yes | State-stored + audit log |
| Agent *definition* | Version history needed | No | Config versioning suffices | Yes | State-stored + explicit versions |
| WorkflowDefinition | Version history needed | No | Version rows suffice | Yes | State-stored + immutable version rows |
| Document | No | Pipeline states only | No | Yes | State-stored + status transitions |
| UsageRecord | It *is* immutable data | No aggregate | Yes but no fold | Unbounded | Append-only table, not event-sourced |
| Integration credential | No — and history is a liability | No | No | Yes | State-stored, rotate + destroy |

Note the last row: for secrets, retaining history is a **security defect**, not a feature. Event sourcing would
make rotation meaningless because old values persist forever. This is the clearest example of why the pattern
must not be universal.

## Considered alternatives

### A. Event source everything
**Advantages:** uniform infrastructure; complete history for any future question.
**Disadvantages:** as above — permanent schema commitments across dozens of aggregates, an erasure problem in
every context, and enormous onboarding cost. Also actively harmful for credentials.

### B. Event source nothing; rely on audit logs + change tables
**Advantages:** simple, familiar, fast to build.
**Disadvantages:** audit logs written *alongside* state can drift from it (a bug updates the row and skips the
log). FR-308 and FR-405 require that the timeline **be** the truth, not a parallel narrative that may disagree.
For workflow runs, "what state was this run in when it made that call?" becomes unanswerable.

### C. Selective event sourcing *(chosen)*

## Decision

**Event-source exactly: `WorkflowRun`, `AgentExecution`, `ApprovalRequest`, and the `AuditTrail`.**
Everything else is state-stored with an audit log.

Supporting infrastructure to be built once and shared:

| Mechanism | Approach |
|-----------|----------|
| **Event store** | `event_store_events` — partitioned, `(stream_id, sequence)` unique, append-only, RLS-scoped |
| **Optimistic concurrency** | Append asserts `expected_sequence`; unique violation → reload, re-decide, retry (bounded) |
| **Snapshots** | Every N=100 events; snapshot is a cache, never authoritative; corrupt/missing snapshot ⇒ full replay |
| **Versioning** | `event_type` + `event_version`; additive-only within a major version (INV-10) |
| **Upcasting** | Registered upcasters chain v1→v2→v3 at *read* time; stored bytes are never rewritten |
| **Replay** | Deterministic fold from sequence 0 (or snapshot); pure functions, no I/O in appliers |
| **Correction** | Compensating events only — see below |

### Correcting history without destroying it

Requirement from the brief: correct historical data without silently destroying original history. Three
mechanisms, in order of preference:

1. **Compensating event** (default). The mistake stays; a `*Corrected` event records the fix, its reason, and
   its author. Folds apply both. History remains truthful about the fact that a mistake was made.
2. **Redaction event + crypto-shredding** (for personal data under NFR-602). The event remains structurally
   present with its payload rendered unreadable by destroying the per-subject key. The *shape* of history is
   preserved; the content is gone. A `Redacted` marker records who authorized it and under what legal basis.
3. **Stream rewrite** (last resort, e.g. a bug wrote structurally invalid events). Requires: an approved
   incident record, the original stream copied verbatim to `event_store_quarantine`, a `StreamRewritten`
   marker in the new stream pointing at the quarantined copy, and a dual-control approval. **Never silent,
   never lossy, always attributable.**

## Why

The four chosen aggregates are precisely the ones where a customer, an auditor, or an on-call engineer will
ask *"what exactly happened, in order, and why?"* — and where answering with a mutable current-state row plus
a separate log is not credible. Everywhere else, the pattern's costs exceed its benefits.

Refusing to event-source credentials and configuration is as much a part of this decision as adopting it for
runs; a reviewer should be able to point at any state-stored aggregate and find it in the table above.

## Consequences

- Four aggregates require domain code written as `decide(command, state) → events` and `apply(event, state) → state`,
  with **no I/O inside `apply`** (this is what makes replay deterministic and is enforced by review + tests).
- Adding a field to one of these events is additive-only, forever (INV-10).
- Snapshot format changes require a snapshot-version bump and are safe because snapshots are disposable.
- The erasure workflow (UC-10) must handle these four streams specifically.
- New engineers need the [event sourcing guide](../04-distributed-systems/event-sourcing.md) before touching
  workflow or agent internals.

## Failure modes

| Failure mode | Detection | Impact | Mitigation |
|--------------|-----------|--------|------------|
| Concurrent append to same stream | Unique violation on `(stream_id, sequence)` | Command retried | Bounded retry with re-decision; excessive conflicts alert on contention hot spots |
| Non-deterministic `apply` (e.g. reads clock or DB) | Replay-equivalence test: fold twice, compare | **Corrupt reconstruction** | Purity enforced by test that replays every stream in CI fixtures and compares to stored snapshot |
| Missing upcaster after a version bump | Deserialization error on old events | Replay fails | Registry completeness test: every `(type, version)` present in the store has a path to current |
| Snapshot inconsistent with events | Checksum comparison during periodic verification | Wrong state served | Snapshots are advisory; verification job rebuilds and compares; mismatch ⇒ delete snapshot, alert |
| Stream grows unbounded (a run that never ends) | Stream length metric | Slow replay, memory pressure | FR-307 ceilings terminate runaway runs; alert at 10× expected length |
| Event payload contains personal data that later needs erasure | Data classification review at schema registration | Legal exposure | Personal data goes in the per-subject-key-encrypted envelope from the start, not in plain payload |
| Replay of a huge stream blocks a request | Latency on aggregate load | Timeouts | Snapshots + a hard cap: load beyond N events happens in a job, not a request |

## Operational impact

New procedures: snapshot verification (scheduled), replay-equivalence checks (CI), stream quarantine handling
(rare, dual-control). Debugging improves dramatically for the four chosen aggregates — the timeline *is* the
data.

## Cost impact

Storage grows with event count rather than entity count; for workflow runs this is roughly 10²–10³× the
row count of a state-stored model, mitigated by partition rotation and cold-tier archival
([data retention](../06-data/data-retention.md)). Compute cost of replay is bounded by snapshots.

## Security impact

- **Positive:** tamper-evidence for the audit trail (hash-chained), complete attribution of AI actions
  (FR-405), no "who changed this?" gaps for runs and approvals.
- **Negative:** immutability conflicts with erasure. Explicitly addressed by mechanism (2) above; the design
  requires that personal data be encrypted per-subject *at write time*, which must be enforced when event
  schemas are registered, not discovered at erasure time.

## Scalability impact

Event volume is dominated by `WorkflowRun` and `AgentExecution` streams. Modeled in
[capacity planning](../10-performance/capacity-planning.md). Partitioning is by time with tenant-hash
sub-partitions; a single stream is always read by `(stream_id, sequence)` range, which is index-local and
scales fine to 10⁹ total rows.

## Related decisions

[ADR-002](ADR-002-database.md) · [ADR-003](ADR-003-event-bus.md) · [ADR-004](ADR-004-cqrs.md) ·
[ADR-006](ADR-006-workflow-engine.md) · [ADR-010](ADR-010-consistency-model.md)

## Related code

`apps/control-plane/infrastructure/event_store/` ·
`domains/workflows/internal/aggregates/` · `domains/agents/internal/aggregates/`

## Related diagrams

[Event sourcing](../04-distributed-systems/event-sourcing.md) ·
[Workflow execution](../03-domains/workflows/runtime.md)
