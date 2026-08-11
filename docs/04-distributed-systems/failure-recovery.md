# Failure Recovery

> What happens when a process dies mid-operation — and which of these claims have actually been tested.
>
> **Status:** 🟡 the recovery paths in the event backbone are implemented and tested. Workflow lease reclaim
> is Phase 7; systematic fault injection is Phase 16. Everything below is labelled accordingly.

---

## The assumption everything is built on

**A deploy is a mass process kill.** Not an exceptional event — a routine, frequent one. Every worker, relay
and consumer is terminated mid-flight several times a week by design.

So "what happens if this process dies here?" is not a hypothetical to handle later. It is the question that
determines whether an operation is written correctly, and it has to be asked at every step boundary
([INV-07](../02-architecture/architecture-constitution.md#inv-07--durable-execution-state-never-lives-in-process-memory)).

## The four recovery patterns in use

**Retry from durable state.** The operation's resumption point is in PostgreSQL before it is attempted, so a
restarted process picks up where the dead one stopped. Outbox rows, scheduled jobs and step executions all
work this way.

**Redeliver and deduplicate.** The message is redelivered because the consumer never committed its cursor;
the [inbox](inbox-pattern.md) makes the second delivery harmless. This is the backbone's entire recovery
story, and it is why [idempotency](idempotency.md) is a precondition rather than a nicety.

**Lease expiry.** A worker holds a lease that *expires* rather than a lock that does not survive a crash.
Expiry is evaluated with the database's clock, and a fence token lets a resumed zombie worker's writes be
rejected. `run_leases` exists; the reclaim loop is Phase 7.

**Rebuild.** Derived data is reconstructed from the log rather than recovered. A projection failure is a
delay, not data loss — see [CQRS](cqrs.md).

## Tested recovery paths

These have executing tests today, in `spec/events/backbone_spec.rb`:

| Failure | Recovery | Assertion |
|---------|----------|-----------|
| Relay dies after publishing, before marking | Restart republishes; the log's unique index absorbs it | The log holds exactly **one** entry |
| Consumer redelivered an event it processed | Inbox claim already exists | The handler ran **once** |
| Handler fails mid-transaction | Claim rolls back with it | The message stays retryable — no inbox row survives |
| Handler fails repeatedly | Dead-lettered with payload and error; cursor advances | The partition keeps moving |
| Two writers append to one aggregate | Unique index rejects the loser | `ConcurrencyConflict`, winner's history intact |

## Untested claims — read this before trusting the matrix

Every "Recovery" cell in [failure-domains.md](../02-architecture/failure-domains.md) that is not in the table
above is a **hypothesis**. It describes intended behaviour that has not been demonstrated
([TD-003](../technical-debt.md)).

This is the most dangerous category of documentation in the repository, because it is *confidently* wrong if
any assumption is off. Untested recovery paths do not work — that is not cynicism, it is the base rate.
Phase 16 exists to convert these into the table above.

## Failure classes and their honest status

| Dependency fails | Design intent | Status |
|------------------|---------------|--------|
| Relay process | Rows stay unpublished; restart resumes | ✅ tested |
| Consumer process | Cursor un-advanced; redelivery + dedup | ✅ tested |
| Broker / transport | Events accumulate in the outbox; nothing lost | 🟡 reasoned; the Postgres transport cannot fail independently |
| PostgreSQL primary | Ingestion and processing stop; no silent loss | ⬜ untested (Phase 16) |
| Redis | Degraded cache and push only ([INV-08](../02-architecture/architecture-constitution.md#inv-08--redis-is-never-the-source-of-truth-for-durable-business-state)) | ⬜ untested — Redis is not installed |
| Worker mid-step | Lease expires; another worker reclaims | ⬜ engine is Phase 7 |
| Model provider | Degrade to humans, never to silent wrong answers | ⬜ runtime is Phase 8 |

## The rules that hold across all of them

**Ingestion never depends on processing.** A downstream outage accumulates work; it does not reject it.

**Derived data failure is never data loss.** Projections, caches and indexes are rebuildable by construction.

**Crash-after-effect is designed for, not hoped about.** Idempotency keys come from durable identifiers so
that a retry after an unknown outcome presents the same key.

**Prefer availability of the partition over strict ordering.** A poison message is dead-lettered and the
partition continues; the alternative is one bad event stalling a tenant indefinitely.

## Related

[Failure domains](../02-architecture/failure-domains.md) · [Inbox](inbox-pattern.md) ·
[Idempotency](idempotency.md) · [CQRS](cqrs.md) · [Technical debt](../technical-debt.md)
