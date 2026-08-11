# Project State

> **Read this first when resuming work after any break in continuity.** It is the single place that records
> where the project actually is, as opposed to where the documentation describes it eventually being.
>
> **Last updated:** 2026-08-10 · **Current phase:** 4 (Core domain model)

---

## ⚠️ Documentation-vs-implementation status

Much of `/docs` describes the **designed** system. Implementation trails design by design (ADRs are written
first, [INV-25](../02-architecture/architecture-constitution.md#inv-25--significant-architectural-decisions-have-an-adr-written-before-implementation)).
Every document that describes something not yet built must say so. Where this file and a subsystem doc
disagree about what exists, **this file wins**.

| Legend | Meaning |
|--------|---------|
| ✅ | Implemented and tested |
| 🟡 | Partially implemented |
| 📐 | Designed (ADR/doc exists), not implemented |
| ⬜ | Not started |

---

## Phase status

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Requirements & domain analysis | ✅ |
| 1 | Architecture & ADRs (Constitution, ADR-001…010) | ✅ |
| 2 | Repository structure & foundations | ✅ |
| 3 | Identity & multi-tenancy | ✅ isolation verified; password + TOTP + tokens implemented (SSO deferred to 13) |
| 4 | Core domain model | ✅ 2 tables deferred on unresolved questions (TD-010) |
| 5 | Event infrastructure | ⬜ next |
| 6 | CQRS & event sourcing | ⬜ |
| 7 | Durable workflow engine | ⬜ |
| 8 | Agent runtime | ⬜ |
| 9 | Tool system & governance | ⬜ |
| 10 | RAG & knowledge | ⬜ |
| 11 | Frontend | ⬜ |
| 12 | Observability | ⬜ |
| 13 | Security hardening | ⬜ |
| 14 | Infrastructure & Kubernetes | ⬜ |
| 15 | Multi-region | ⬜ |
| 16 | Chaos engineering | ⬜ |
| 17 | Performance & capacity | ⬜ |
| 18 | Disaster recovery | ⬜ |
| 19 | Adversarial self-review | ⬜ |
| 20 | Documentation audit & scorecard | ⬜ |

---

## Component status

| Component | Status | Notes |
|-----------|--------|-------|
| Requirements register (FR/NFR) | ✅ | [requirements.md](../01-product/requirements.md) |
| Architecture Constitution v1.0 | ✅ | 26 invariants, enforcement mapped |
| ADR-001 … ADR-011 | ✅ | All accepted |
| Context map & ownership register | ✅ | [context-map.md](../02-architecture/context-map.md) |
| Failure matrix (33 rows) | ✅ | Recovery behaviors are **hypotheses** until chaos tests exist |
| Docs consistency checker | ✅ | `tools/docs-lint` — 6 rules, planned-docs manifest, CI-blocking |
| Boundary checker | ✅ | `tools/boundary-check` — 6 rules + self-test against a known-bad fixture |
| Migration linter | ✅ | `tools/migration-lint` — 6 rules (INV-11/13/14) + self-test; closes TD-005 |
| INV-13 exemption list | ✅ | `ownership.yml:tenant_exempt` — the "enumerated explicitly" INV-13 requires, now machine-checked |
| Navigation docs (start-here, map, tour, onboarding, code map) | ✅ | |
| Architecture diagrams L2–L4 | ✅ | container, component, request/event/data flow, deployment |
| Rails control plane skeleton | ✅ | Boots; Zeitwerk clean; `Nexus::*` namespace; roles declared |
| Database schema (55 tables) | ✅ | 10 migrations applied to dev + test |
| Core domain schema (40 tables) | ✅ | Events, Workflows, Agents, Integrations, Documents, Notifications, Billing, Audit ([ADR-012](../11-decisions/ADR-012-domain-schema.md)) |
| Schema conformance suite (7 examples) | ✅ | Asserts RLS from `pg_class`/`pg_policies` for every tenant table; mutation-tested |
| Data documentation | ✅ | [schema](../06-data/schema.md) + [database architecture](../06-data/database-architecture.md); the other seven `06-data` docs re-declared to phases 6/10/13/17 |
| `chunk_embeddings`, `usage_records` | ⬜ | **Deliberately not created** — blocked on Q4/Q5; see TD-010 |
| Row-Level Security (11 policies, FORCE) | ✅ | Verified fail-closed on a non-superuser connection |
| Tenant context + scoped record | ✅ | All three INV-14 layers, each independently tested |
| Least-privilege DB roles | ✅ | `db/roles.sql` — nexus_app / nexus_ro, NOSUPERUSER NOBYPASSRLS |
| Isolation suite (10 examples) | ✅ | Proven non-vacuous by mutation |
| Tenant provisioning contract | ✅ | `Organizations::ProvisionOrganization` |
| Permission catalog (44 keys, 4 risk tiers) | ✅ | Platform-global; `PermissionCatalog.install!`, idempotent, run by `db:seed` |
| System roles with attached permissions | ✅ | owner/admin/operator/viewer, expanded to explicit rows at seed time |
| Authorization evaluator | ✅ | Deny-by-default, ABAC overlay, fails closed on every error path (INV-15) |
| Delegation intersection (INV-16) | ✅ | `PermissionSet#effective_for`; no union exists in the code; cycle-bounded |
| Role assignment contract | ✅ | `Authorization::AssignRole`, required `authorized_by:`, `:system_bootstrap` hatch is greppable |
| Authorization suite (51 examples) | ✅ | Proven non-vacuous by mutation (union → 3 fail; no deny-by-default → 16 fail) |
| Password + TOTP authentication | ✅ | Uniform failure, constant-time dummy bcrypt, TOTP replay floor |
| Access + refresh tokens | ✅ | JWT identity-only claims; rotation with family reuse detection ([ADR-011](../11-decisions/ADR-011-authentication.md)) |
| `Identity::Principal` | ✅ | Identifiers only; satisfies Authorization's structural contract without either context naming the other |
| Machine identities (services, agents) | ✅ | `nxs_<tenant>_<secret>`; digest lookup runs inside RLS |
| `Organizations::Membership` query | ✅ | Lets Identity resolve a membership without reading the table (INV-01) |
| Identity suite (59 examples) | ✅ | Mutation-tested; includes an end-to-end login → `Authorize` path |
| SSO (OIDC/SAML) | ⬜ | Phase 13 — behind the same `Authenticate` contract |
| HTTP API surface (controllers, routes) | ⬜ | **The next blocker**: every piece a request needs now exists, but only `/up` is routed |
| Domain models for events/workflows/agents/etc. | ⬜ | Phase 4 remainder |
| Everything downstream | ⬜ | — |

---

## Environment reality (as verified on this machine)

Recorded because several design decisions were adjusted to it, and because a future reader will otherwise
wonder why the local topology differs from production.

| Dependency | Status | Consequence |
|-----------|--------|-------------|
| Ruby 3.2.2 / Rails 7.1 | ✅ available | Control-plane target runtime |
| PostgreSQL 14 | ✅ running locally | **The design targets PG 16** (RLS + partitioning features used are available in 14, but verify before relying on 16-only syntax) |
| Node 24 | ✅ available | Frontend toolchain |
| Docker daemon | ❌ unavailable (WSL2) | Dockerfiles and compose files are written but **unverified by execution** |
| Redis | ❌ not installed | Local runs use the null cache adapter; INV-08 already requires Redis to be non-authoritative, so this is a degradation, not a blocker |
| Kafka | ❌ not installed | Local/CI uses `PostgresLogTransport` — the reason [ADR-003](../11-decisions/ADR-003-event-bus.md) specifies a transport port |
| `pgvector` | ❌ not available | Not in `pg_available_extensions`. `chunk_embeddings` cannot be created here at all — one of two independent reasons it was deferred ([ADR-012](../11-decisions/ADR-012-domain-schema.md)) |

> The Kafka gap is the clearest example of a constraint improving the design: needing the full event path to
> run against PostgreSQL alone is what makes the correctness tests (duplicate delivery, replay, crash recovery)
> runnable in CI at all.

---

## Active architectural decisions

All ten ADRs are in force. Positions most likely to be challenged, with the evidence that would reopen them:

| Decision | Challenge | Reopens when |
|----------|-----------|--------------|
| [ADR-006](../11-decisions/ADR-006-workflow-engine.md) build the engine | Highest-risk decision in the set | > 5k steps/s/region with DB proven bottleneck; **or** ≥ 2 crash-recovery incidents/year; **or** > 15% of capacity on engine maintenance |
| [ADR-008](../11-decisions/ADR-008-vector-database.md) pgvector | Will not hold at large corpora | > 50 M chunks/region; recall@10 < 0.90; retrieval p95 > 200 ms |
| [ADR-002](../11-decisions/ADR-002-database.md) single datastore | Search and metering will strain it | Postgres FTS p95 > 300 ms; usage aggregation p95 > 2 s |
| [ADR-001](../11-decisions/ADR-001-architecture-style.md) monolith | Boundary erosion | `boundary-check` downgraded from blocking to warning — that alone invalidates the ADR's core assumption |

---

## Unresolved questions

| # | Question | Blocking | Owner | Notes |
|---|----------|----------|-------|-------|
| Q1 | Which secrets manager (cloud KMS vs. Vault) backs envelope encryption? | Phase 13 | Security | Affects credential storage and crypto-shredding key hierarchy |
| Q2 | Do dedicated-tier tenants get their own Kafka topics or a shared cluster with ACLs? | Phase 14 | SRE | Cost vs. isolation; ADR-003 permits both |
| Q3 | Sandbox technology for workflow "code" steps (gVisor / Firecracker / WASM)? | Phase 7 | Platform | Untrusted code execution — may be deferred by shipping without code steps |
| Q4 | Embedding model choice and dimensionality | Phase 10 | AI | Determines vector storage sizing in capacity model |
| Q5 | Is `usage_records` per-event or pre-aggregated per execution? | Phase 9 | Data | Trade-off between attribution granularity and row volume at 10⁸ users |
| Q6 | Retention period for `ingested_events` raw payloads | Phase 5 | Compliance | Interacts with NFR-602 erasure |

**Rule:** an unresolved question that starts blocking implementation gets an ADR, not a hallway decision.

---

## Known technical debt

Tracked in full in [technical-debt.md](../technical-debt.md). Current items:

| ID | Item | Impact |
|----|------|--------|
| TD-001 | Docker/compose files unverified (no daemon on the dev machine) | Deployment claims untested |
| TD-002 | Local PostgreSQL is 14; design targets 16 | Version-specific syntax risk |
| TD-003 | Every "recovery" row in the failure matrix is a hypothesis until Phase 16 | Documentation asserts behavior not yet demonstrated |
| TD-007 | MFA secrets use application-level encryption, not envelope encryption (blocked on Q1) | INV-18 only partially satisfied |
| TD-009 | High-volume tables unpartitioned; partitioning gated on a per-partition RLS control | A known future migration cost, preferred over an unverifiable isolation rule |
| TD-010 | `chunk_embeddings` and `usage_records` not created (Q4/Q5 unresolved) | Blocks completion of Phases 9 and 10 |

---

## Known bugs

None open. Three defects were found and fixed during Phase 3 — see [security findings](../security/findings.md) SEC-001/002/003.

---

## Repository structure (current, not aspirational)

```
aegis-nexus/
├── docs/                 ✅ substantial
│   ├── 00-start-here/    🟡
│   ├── 01-product/       ✅
│   ├── 02-architecture/  🟡 (constitution, context map, overview, failure domains, principles)
│   ├── 03-domains/       ⬜ directories exist, empty
│   ├── 04-…13-…          ⬜ directories exist, empty
│   └── 11-decisions/     ✅ ADR-001…010 + README + template
├── apps/control-plane/   ✅ boots, autoloads, zero boundary violations
│   ├── app/              🟡 delivery layer (ApplicationRecord only)
│   ├── domains/          🟡 11 contexts scaffolded; Authorization stub
│   ├── infrastructure/   ⬜ directories only
│   └── config/           ✅ ownership.yml, roles.yml, application.rb
├── infra/docker/         🟡 Dockerfile + compose written, UNVERIFIED (TD-001)
└── tools/                ✅ docs-lint + boundary-check, both CI-blocking
```

---

## Important assumptions

1. **Multi-tenant from row zero.** Retrofitting `organization_id` later is not a plan.
2. **At-least-once everywhere.** Any handler assuming single delivery is a latent bug.
3. **Deploys are mass process kills.** Any state not persisted before a deploy is lost work.
4. **Model providers are unreliable and adversarially influenceable.** Both are true simultaneously.
5. **Documentation is a build artifact.** If CI does not check it, it will drift, and drifted docs are worse
   than none because they are trusted.

---

## Resuming work — checklist

1. Read this file.
2. Read the [Constitution](../02-architecture/architecture-constitution.md) — it is short and binding.
3. Check the phase table; pick up the first 🟡 or ⬜.
4. Before implementing anything architectural, check whether an ADR exists. If not, write it first (INV-25).
5. When done, update: this file, the [changelog](../architecture-changelog.md) if architecture changed, and
   the affected subsystem docs — in the same change (INV-26).
