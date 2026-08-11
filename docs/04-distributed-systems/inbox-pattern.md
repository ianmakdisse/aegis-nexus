# The Inbox Pattern

> How at-least-once delivery becomes effectively-once processing.
>
> **Status:** ✅ implemented (Phase 5). Enforces
> [INV-05](../02-architecture/architecture-constitution.md#inv-05--every-distributed-operation-is-idempotent).

---

## Why duplicates are guaranteed, not hypothetical

The [outbox relay](outbox-pattern.md) publishes and then marks. A crash between those steps republishes on
restart. A consumer that processes an event and then crashes before committing its cursor re-reads it. A
rebalance redelivers everything after the last commit.

None of these are bugs to be fixed. They are the cost of not losing messages, and the trade is deliberate:
**re-reading a processed event is harmless; skipping an unprocessed one is data loss.** So every mechanism
here errs toward redelivery.

The inbox is what makes that safe.

## The mechanism

Before running a handler, the consumer claims the right to process, keyed by `(organization_id,
consumer_group, dedup_key)`. A unique index makes the claim atomic.

```ruby
InboxMessage.claim(consumer_group: "orders", dedup_key: envelope.event_id)
# => true  : you own it, run the handler
# => false : someone already did, skip
```

Checking first with a `SELECT` would be a race two concurrent consumers both win. Catching the unique
violation is what makes it correct under concurrency.

## Two implementation details that are not optional

**The claim and the handler share one transaction.**

The obvious implementation claims first, then calls the handler. If the handler then fails, the claim
survives — and every retry is deduplicated away. The message is silently and permanently dropped, which is
*worse* than the duplicate the inbox existed to prevent.

Both happen in one transaction. A failed handler rolls the claim back and the message is genuinely retryable.

**The claim runs inside a savepoint.**

In PostgreSQL a failed statement aborts the entire transaction. Rescuing `RecordNotUnique` without a savepoint
*looks* like it handles the duplicate while leaving the surrounding transaction poisoned — the next query
raises `PG::InFailedSqlTransaction`, and the message is dead-lettered as a handler failure rather than
recognised as the duplicate it is.

> This was a real defect, found by the duplicate-delivery test rather than by review. It is recorded here
> because the correct-looking version is genuinely hard to spot in a diff.

## Choosing a dedup key

The base consumer **refuses to run a handler that does not declare one**. Not a warning — a refusal, because
a handler without a key is a double charge, a double notification, or a double side effect waiting for the
next relay restart.

| Good key | Why |
|----------|-----|
| `envelope.event_id` | Unique per event; the right default for projections |
| `"#{run_id}:#{step_key}:#{attempt}"` | Derived from durable identifiers, so a retry produces the same key |
| `"#{aggregate_id}:#{sequence}"` | Stable across redelivery and replay |

| Bad key | Why |
|---------|-----|
| `SecureRandom.uuid` | Different on every delivery — deduplicates nothing |
| `Time.now.to_i` | Same failure, wearing a clock |
| `payload.hash` | Two legitimately identical events collapse into one |

The rule: **derive the key from something that survives a restart.** If a retry would compute a different key,
it is not a dedup key.

## Retention

Inbox rows accumulate. They are safe to prune once no producer could still redeliver an event that old —
bounded by the log's retention, not by the inbox's own size. Pruning is a Phase 12 concern and is deliberately
not implemented yet; the table is small at current volumes and an unimplemented reaper is more honest than an
untuned one.

## Related

[Outbox](outbox-pattern.md) · [Idempotency](idempotency.md) · [Failure recovery](failure-recovery.md) ·
[Events](../03-domains/events/README.md)
