# Ordering Guarantees

> What order things happen in, and — more usefully — what order they do not.
>
> **Status:** ✅ implemented (Phase 5).
> [INV-09](../02-architecture/architecture-constitution.md#inv-09--ordering-is-per-key-never-global).

---

## The guarantee

**Events sharing a partition key are delivered in the order they were committed. Nothing else is ordered.**

That is the entire promise. It is deliberately narrow, because it is the strongest thing that remains true
when the system is running on many machines, and every wider promise is one that quietly breaks under load.

## What is explicitly not guaranteed

| Not guaranteed | Why people expect it anyway |
|----------------|----------------------------|
| Global ordering across all events | It looks true in development, where there is one process and one partition |
| Ordering across different partition keys | Two aggregates' events interleave arbitrarily, and always will |
| That a later `occurred_at` means "happened after" | Clocks on different machines disagree; skew is normal, not a fault |
| That a consumer sees events in the order a *user* performed them | Only if those actions shared a key |

**Wall-clock time is not a coordination primitive.** Timestamps here are for humans and for audit, never for
deciding what happened first. Where the system needs "before", it uses a sequence number
([event sourcing](event-sourcing.md)) or the database's own clock (lease expiry).

## Choosing the partition key

Choosing the key *is* choosing what is ordered. It is a design decision, not a plumbing detail.

| Key | Orders | Costs |
|-----|--------|-------|
| Aggregate id (the default) | Everything about one run, agent, or approval | Nothing — this is almost always right |
| Tenant id | Everything in one tenant | Serialises a whole tenant; large tenants become a bottleneck |
| Constant | Everything | Throughput of one partition. Never do this |
| Random | Nothing | Maximum parallelism, zero ordering |

`Envelope` **requires** a partition key and refuses a blank one at construction. A missing key would otherwise
surface much later as one aggregate's events processed out of order — close to undebuggable, because the code
that caused it is nowhere near the failure.

## How it is implemented

```ruby
partition = Zlib.crc32(partition_key) % Transport::PARTITIONS   # 16
```

Same key → same partition → same reader → committed order preserved. Within a partition the log is dense and
gapless, enforced by a unique index on `(organization_id, topic, partition_number, position)`; a relay retry
cannot write two entries at the same position, which would silently reorder the log.

Partition count is a property of the transport, not a tuning knob: changing it re-shuffles which keys share a
partition, so it is a migration.

## Consequences you have to design around

**Two aggregates cannot be coordinated by ordering.** If a handler needs "A happened before B" across
different keys, ordering will not give it. Use an explicit causal reference (`causation_id`), a state check on
the aggregate itself, or a workflow that sequences them.

**Ordering is per partition, but *processing* is per tenant here.** The PostgreSQL transport reads every
partition for one tenant before moving on. Order within a key still holds; order across keys is arbitrary, as
promised.

**A poison message advances the cursor.** After the retry budget it is dead-lettered and the partition
continues. Blocking would preserve strict order at the cost of stalling every other key in that partition
indefinitely — one bad event becoming a tenant-wide outage. Availability wins, and the dead letter records
what was skipped.

## Related

[Idempotency](idempotency.md) · [Inbox](inbox-pattern.md) · [Event sourcing](event-sourcing.md) ·
[ADR-003](../11-decisions/ADR-003-event-bus.md)
