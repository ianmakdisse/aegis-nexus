# boundary-check

Enforces the bounded-context boundaries that
[ADR-001](../../docs/11-decisions/ADR-001-architecture-style.md) depends on.

```bash
ruby tools/boundary-check/check.rb              # check apps/control-plane
ruby tools/boundary-check/check.rb --format=json
./tools/boundary-check/self-test.sh             # prove the checker still works
```

## Why this is load-bearing

ADR-001 chose a modular monolith over microservices on **one explicit
assumption**: that module boundaries would be enforced mechanically rather than
by discipline. In a microservice architecture the network enforces boundaries
for you; in a monolith, nothing does — unless something like this exists.

So this tool is not a linter. It is the mechanism that makes the architecture
decision valid. The ADR says so explicitly:

> Boundary violations must be treated as build failures, not warnings. The moment
> they become warnings, this ADR's central assumption is void and (A) —
> microservices — becomes correct by default.

If you are about to add `--allow-failure` to this check in CI, you are not
relaxing a lint rule; you are changing the system's architecture. Write an ADR.

## Rules

| Rule | Invariant | Detects |
|------|-----------|---------|
| `cross-context-table` | [INV-01](../../docs/02-architecture/architecture-constitution.md#inv-01--a-bounded-context-owns-its-tables-exclusively) | A context naming a table another context owns (models, `from(...)`, raw SQL) |
| `private-access` | [INV-02](../../docs/02-architecture/architecture-constitution.md#inv-02--the-published-contract-is-the-only-public-surface) | Reaching into another context's `Internal::` namespace |
| `undeclared-public` | INV-02 | A constant at a context's top level that `ownership.yml` does not declare public |
| `undeclared-sync` | [INV-03](../../docs/02-architecture/architecture-constitution.md#inv-03--contexts-communicate-asynchronously-by-default) | A synchronous cross-context call not listed in `sync_allowed` |
| `raw-publish` | [INV-04](../../docs/02-architecture/architecture-constitution.md#inv-04--no-dual-writes) | Direct broker-client use outside the Events context |
| `unowned-table` | [INV-13](../../docs/02-architecture/architecture-constitution.md#inv-13--every-business-row-is-attributable-to-exactly-one-tenant) | A migration creating a table no context owns |

## The ownership register

Everything is driven by
[`apps/control-plane/config/ownership.yml`](../../apps/control-plane/config/ownership.yml) — the
machine-readable form of the [context map](../../docs/02-architecture/context-map.md).

Adding a `sync_allowed` entry requires a `why`. That field exists because a
synchronous cross-context dependency is an availability multiplier, and the
reviewer's job is to ask whether the caller genuinely cannot proceed without the
answer. "It was easier" is a reason, just not a good one — and writing it down
makes that visible.

## Self-test

`self-test.sh` runs the checker against
[`fixtures/bad-app`](fixtures/), a deliberately non-compliant module that
violates four rules at once, and asserts all four fire.

A checker that silently stops checking is worse than no checker, because the
architecture then *believes* it is protected. The self-test runs in CI alongside
the real check.

## Known limits

Static text analysis, so it is deliberately conservative:

- Table references are detected by name. A table accessed through a variable or
  built by string interpolation is not caught.
- Cross-context calls through metaprogramming (`const_get`, `send`) are not caught.
- It cannot detect *semantic* coupling — two contexts that technically respect
  the boundary while being impossible to change independently.

These gaps are the reason the [context map](../../docs/02-architecture/context-map.md)
also tracks **extraction difficulty** per context: a context whose difficulty
rises over time is evidence of erosion the static check cannot see.
