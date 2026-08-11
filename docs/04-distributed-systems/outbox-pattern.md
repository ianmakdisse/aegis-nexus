# The Outbox Pattern

> How a state change and its event become one atomic fact.
>
> **Status:** ✅ implemented (Phase 5). Enforces
> [INV-04](../02-architecture/architecture-constitution.md#inv-04--no-dual-writes).

---

## The bug this exists to make unwritable

```ruby
order.save!                        # committed
Kafka.produce("order.placed", …)   # process dies here
```

The state changed. The event did not. Nothing raised, nothing retried, and the two halves of the system now
disagree — permanently, and **undetectably**, until someone builds the reconciliation tooling that nobody
builds until after the incident.

Reversing the order does not help; it produces the mirror bug, an event for a change that never committed.
There is no ordering of two independent writes that is safe, which is the whole point: **the problem is that
there are two writes.**

## The mechanism

There is one write. The event goes into a table, in the same transaction as the state it describes.

```
BEGIN
  UPDATE domain state
  INSERT outbox_messages     ← the event
  INSERT audit_records       ← the evidence
COMMIT
```

All three commit or none do. A separate process — the `relay` role — reads committed outbox rows afterwards
and publishes them.

This is why [ADR-002](../11-decisions/ADR-002-database.md) chose a single authoritative datastore. With one
transaction boundary the guarantee is **structural**: a property of the commit, not a protocol between two
components that must both be working at the same instant.

## How it is enforced

`Nexus::Events::Publisher` raises `NotInTransaction` if called outside a transaction — before writing
anything. Not a warning, not a log line:

```ruby
def assert_in_transaction!
  return if ActiveRecord::Base.connection.transaction_open?
  raise NotInTransaction, "…the event must commit with the state it describes…"
end
```

`boundary-check` independently rejects any direct broker client outside the Events context
(`raw-publish`, INV-04), so the shortcut cannot be taken elsewhere either.

## What the relay guarantees, and what it does not

**At-least-once.** The relay publishes, then marks the row published. A crash between those two steps
republishes on restart — this is the normal case, not an edge case.

The duplicate is absorbed by a unique index on `(organization_id, outbox_message_id)` in the log. Crucially,
the relay **could** make publish-and-mark atomic on PostgreSQL and deliberately does not: Kafka cannot, so an
atomic relay would behave differently per transport and the duplicate path — the one that runs in production —
would never be exercised in CI.

We never claim exactly-once
([INV-06](../02-architecture/architecture-constitution.md#inv-06--we-never-claim-exactly-once-delivery)).
Consumers deduplicate; see [the inbox](inbox-pattern.md) and [idempotency](idempotency.md).

## Why the relay reads per tenant

It would be simpler to scan every unpublished row globally. That requires a role that bypasses row-level
security, and [INV-14](../02-architecture/architecture-constitution.md#inv-14--tenant-isolation-is-enforced-at-three-independent-layers)
permits no such role — so the relay iterates tenants from the platform directory
([ADR-013](../11-decisions/ADR-013-tenant-enumeration.md)) and opens each tenant's context in turn.

The constraint turns out to be a feature: per-tenant iteration gives fairness for free. One tenant's backlog
cannot starve everyone else's.

## Operating it

| Signal | Means |
|--------|-------|
| `outbox_oldest_age_seconds` rising | The relay is behind. **This is the scaling signal for the role** — depth is misleading, because one tenant with a burst looks identical to every tenant stalled |
| Unpublished count flat but nonzero | Publication is failing for specific rows; check `last_error` and `attempts` |
| Everything published, consumers idle | Not an outbox problem — look downstream at consumer lag |

Starving the relay delays everything downstream **while producing no errors at all**, which is why the role
scales on age rather than on queue depth (`config/roles.yml`).

## Related

[Inbox](inbox-pattern.md) · [Idempotency](idempotency.md) · [Ordering](ordering-guarantees.md) ·
[ADR-003](../11-decisions/ADR-003-event-bus.md) · [Events](../03-domains/events/README.md)
