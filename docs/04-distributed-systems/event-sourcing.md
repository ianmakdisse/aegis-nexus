# Event Sourcing

> How four aggregates store their history instead of their state — and why only four.
>
> **Status:** ✅ machinery implemented (Phase 6). The four aggregates themselves land with their runtimes in
> Phases 7, 8 and 10. Decision: [ADR-005](../11-decisions/ADR-005-event-sourcing.md).

---

## The narrow claim

Event sourcing stores an aggregate's history as an ordered sequence of immutable events and derives current
state by folding them. It is powerful and it is expensive, so the question here was never "should we use event
sourcing" but **"for which aggregates is history itself the requirement?"**

Four qualify: `WorkflowRun`, `AgentExecution`, `ApprovalRequest`, `AuditTrail`. Everything else is ordinary
mutable state. Credentials are the clearest counter-example — an append-only log of secrets cannot be
redacted, so event-sourcing them would be actively harmful.

## The mechanism

```
append(stream_id:, stream_type:, events:, expected_sequence:)
load(stream_id:, stream_type:)  →  newest snapshot + every event after it
```

An aggregate is `state = events.reduce(snapshot) { |s, e| apply(s, e) }`.

**Optimistic concurrency is the database's job.** Appending declares the sequence the caller last saw; the
unique index on `(organization_id, stream_id, sequence)` rejects a second writer at that position. A
`SELECT max(sequence)` followed by an `INSERT` is a race that two concurrent workers both win, so the
application-level check is not a check.

That constraint is also why the event store cannot be time-partitioned: a unique index on a partitioned table
must include the partition key, which would permit two events at the same sequence
([ADR-012](../11-decisions/ADR-012-domain-schema.md)).

**Events and their publication commit together.** `append` writes the event rows *and* their outbox rows in
one transaction. An aggregate whose history advanced but whose events never reached the backbone is
[the dual-write bug](outbox-pattern.md) wearing a different hat.

## Appliers are pure functions, and this is the whole discipline

An applier takes state and a payload and returns the next state. It may not read the database, call a service,
generate a random value, or look at the clock.

The reason is replay. Rebuilding re-runs every applier over the entire history — possibly years later,
possibly thousands of times during a [projection rebuild](cqrs.md). An applier that does I/O turns a replay
into a load test. One that reads the clock or a random value produces a **different aggregate each rebuild**,
and at that point history no longer determines state: the event log has become decoration.

Anything non-deterministic belongs in the *command*, computed once and recorded in the payload forever.

```ruby
# wrong — the aggregate is different every time it is rebuilt
on("run.started") { |s, _| s.merge("started_at" => Time.now) }

# right — decided once, at the moment it happened
def start! = emit("run.started", "started_at" => Time.current.iso8601)
```

`spec/events/event_store_spec.rb` rebuilds the same aggregate three times and asserts identical state. If that
test ever fails, every other guarantee on this page is theatre.

## Snapshots are a cache and nothing more

Taken every 100 events, written best-effort, and **never authoritative**. Deleting every snapshot in the
database costs replay time and cannot change an answer — which is exactly why a failed snapshot must never
fail the write that triggered it.

A corrupt snapshot is therefore a performance incident, not a correctness one. The recovery is `DELETE`.

## Unknown event types are ignored, not raised

An older deployment must be able to fold an event a newer one emitted. During a rolling deploy both versions
are live *by design*, so a fold that crashes on an unrecognised type turns every schema addition into an
outage. Ignoring keeps the fold total; combined with [additive-only evolution](../13-reference/events.md), the
old version simply computes state without the new field.

## What this costs

Honest list, since the ADR chose it for four aggregates rather than none or all:

- Every state question becomes a fold, so reads need [projections](cqrs.md).
- Schema commitments are permanent: a stored event will be read by code written years later.
- Erasure is hard — an append-only log conflicts with NFR-602, which is why credentials are excluded and why
  crypto-shredding is the intended remedy elsewhere.
- Debugging requires reading history rather than a row, which is a genuine ramp-up cost for new engineers.

## Related

[CQRS](cqrs.md) · [Ordering](ordering-guarantees.md) · [Consistency model](consistency-model.md) ·
[ADR-005](../11-decisions/ADR-005-event-sourcing.md)
