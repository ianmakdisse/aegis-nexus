# Developer Onboarding

> Get the platform running, understand what the build enforces, and ship a first change.
>
> Check [project-state.md](project-state.md) first — it is authoritative about what actually exists.

---

## Prerequisites

| Tool | Version | Why |
|------|---------|-----|
| Ruby | 3.2+ | Control plane |
| PostgreSQL | 16 (+ `pgvector`) | Authoritative store ([ADR-002](../11-decisions/ADR-002-database.md)) |
| Node | 20+ | Frontend (Phase 11) |
| Docker | optional | Only needed for the compose topology |

**Redis and Kafka are optional.** That is deliberate, not a gap: Redis is never authoritative
([INV-08](../02-architecture/architecture-constitution.md#inv-08--redis-is-never-the-source-of-truth-for-durable-business-state)),
and the event backbone has a PostgreSQL transport so the entire event path — publish, deliver, dedup, replay —
runs without a broker ([ADR-003](../11-decisions/ADR-003-event-bus.md)).

---

## Setup

```bash
git clone <repo> && cd aegis-nexus

# 1. The checks that block CI — no dependencies beyond Ruby
ruby tools/docs-lint/lint.rb
ruby tools/boundary-check/check.rb
./tools/boundary-check/self-test.sh

# 2. Control plane
cd apps/control-plane
cp .env.example .env
bundle install
bundle exec rails zeitwerk:check     # autoloading is sane
bundle exec rails db:prepare
NEXUS_ROLE=api bundle exec rails server
```

Or the full topology:

```bash
docker compose -f infra/docker/docker-compose.yml up
```
> ⚠️ Unverified — see [TD-001](../technical-debt.md). If it fails, fix it and remove that debt entry.

---

## Run a role

One image, nine roles ([`config/roles.yml`](../../apps/control-plane/config/roles.yml)):

```bash
NEXUS_ROLE=api        bundle exec rails server
NEXUS_ROLE=relay      ./bin/role-entrypoint
NEXUS_ROLE=worker:agents ./bin/role-entrypoint
```

An unknown role exits 64 rather than silently defaulting — a typo in a manifest should crash-loop loudly.

---

## What the build enforces

These are not style gates. Each is the mechanism an ADR depends on.

| Check | Blocks on | If it fails |
|-------|-----------|-------------|
| `docs-lint` | Broken links/anchors, undeclared forward references, stale plans | Fix the link or declare it in `planned-docs.yml` |
| `boundary-check` | Cross-context tables, `Internal::` access, undeclared sync calls, raw broker use | You crossed a boundary — use the published contract |
| `boundary-check self-test` | The checker no longer detecting known violations | The checker broke; fix it before trusting a green build |
| Zeitwerk check | Autoload mismatches | Filename/constant mismatch |
| N/N+1 job | Schema incompatible with the previous release | Expand → migrate → contract (INV-11) |
| Isolation suite | Cross-tenant access with a layer disabled | Treat as a security bug |

> If you're tempted to make one of these non-blocking: `boundary-check` going advisory invalidates
> [ADR-001](../11-decisions/ADR-001-architecture-style.md)'s central assumption. That's an architecture change,
> so it needs an ADR — not a CI flag.

---

## Your first change — the checklist

Before you open the PR:

- [ ] Does an **invariant** cover this? → [Constitution](../02-architecture/architecture-constitution.md)
- [ ] Is this an **architectural decision**? → write the ADR *first* (INV-25)
- [ ] New table? → `organization_id` + RLS + registered in `ownership.yml` (INV-13)
- [ ] New event? → versioned, additive-only, registered in the catalog (INV-10)
- [ ] New consumer? → declares a dedup key; handler is idempotent (INV-05)
- [ ] Publishing an event? → inside the transaction that made the state change (INV-04)
- [ ] Migration? → expand/contract; N and N+1 both work (INV-11)
- [ ] New sync cross-context call? → declared in `ownership.yml` **with a reason** (INV-03)
- [ ] Touching auth or budgets? → reads authoritative state, not a projection ([ADR-010](../11-decisions/ADR-010-consistency-model.md))
- [ ] Docs updated **in this PR** (INV-26)
- [ ] Long-running work? → durable state before it starts (INV-07)

---

## Common mistakes (and the honest reasons they happen)

| Mistake | Why it's tempting | Do instead |
|---------|-------------------|------------|
| Joining another context's table | The data is right there and it's one join | Subscribe to its events, or use its contract |
| Publishing after commit | Feels equivalent | `Publisher` inside the transaction — it raises otherwise |
| Caching an authorization result | It's the obvious latency win | Don't. Revocation must be immediate |
| Reading a projection to enforce a budget | Rollups are convenient | Read authoritative rows |
| `check_exists?` then `insert` | Reads naturally | Insert and handle the unique violation |
| Assuming single delivery | It usually is | Assume duplicates; make them boring |
| Trusting model output | It looks structured | It's untrusted content; authorize the action independently |

---

## Where to ask

1. [System map](system-map.md) — where things live
2. [ADR index](../11-decisions/README.md) — why things are this way
3. [Glossary](glossary.md) / [domain glossary](../01-product/domain-glossary.md) — what a word means here
4. [Technical debt](../technical-debt.md) — whether it's a known problem

If the answer wasn't in `/docs`, **that is a documentation bug.** Fix it in the same PR — you are the only
person who can see what's confusing, and only for a few weeks.
