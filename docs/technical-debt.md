# Technical Debt Register

> Shortcuts are not hidden here. A debt that nobody wrote down is a debt nobody will pay — it just accrues
> interest as confusion.
>
> **Entry rule:** anything knowingly done in a way we would not choose with more time gets an entry, *when it
> is done*, not later. An item removed from this register must be removed because it was fixed, not because it
> became normal.

**Priority:** `P1` fix before the next phase · `P2` fix within the current milestone · `P3` fix when touched ·
`P4` accepted, revisit on trigger

---

## Open items

### TD-001 — Container images and compose files are unverified

| | |
|---|---|
| **Description** | Dockerfiles and `docker-compose.yml` are written but have never been built or run. |
| **Reason** | The development machine is WSL2 with no Docker daemon available. |
| **Impact** | Deployment instructions are unproven. A syntax or layer-ordering error would surface first in CI or, worse, to the next developer. |
| **Risk** | Medium — silent until someone tries to run it, then blocks them entirely. |
| **Effort** | 1–2 hours once any Docker host is available. |
| **Affected** | `infra/docker/`, local development onboarding. |
| **Mitigation** | CI builds the image on every PR, so the first push to a branch verifies it. Until then the README does not claim the containers work. |
| **Priority** | P2 |

### TD-002 — Local PostgreSQL is 14; the design targets 16

| | |
|---|---|
| **Description** | Development runs against PostgreSQL 14; ADR-002 and the CI service image target 16. |
| **Reason** | 14 is what is installed on the development machine. |
| **Impact** | Version-specific syntax could pass locally and fail in CI, or vice versa. |
| **Risk** | Low-medium — the features relied on (RLS, declarative partitioning, `SKIP LOCKED`) exist in 14, but performance characteristics and some planner behavior differ. |
| **Effort** | Small — pin a matching image locally. |
| **Affected** | Every migration and query. |
| **Mitigation** | CI is the source of truth and runs 16. Migrations avoid version-specific syntax without an explicit note. |
| **Priority** | P2 |

### TD-003 — Failure-matrix recovery behaviors are hypotheses

| | |
|---|---|
| **Description** | Every "Recovery" cell in [failure-domains.md](02-architecture/failure-domains.md) describes intended behavior. Almost none has an executing test yet. |
| **Reason** | Chaos engineering is Phase 16; the matrix was written in Phase 1 so the design could be reasoned about. |
| **Impact** | The documentation asserts behavior the system has not demonstrated. This is the single most dangerous kind of documentation debt, because it is *confidently* wrong if any assumption is off. |
| **Risk** | **High** — an untested recovery path is a recovery path that does not work, discovered during an incident. |
| **Effort** | Large — it is essentially Phase 16. |
| **Affected** | All reliability claims. |
| **Mitigation** | The matrix labels the test column explicitly and states that untested rows are hypotheses. `project-state.md` repeats the warning. |
| **Priority** | P1 (for the labeling to stay honest); P2 (for the tests themselves) |

### TD-004 — `boundary-check` is static text analysis

| | |
|---|---|
| **Description** | Boundary enforcement matches names and namespaces in source text. It cannot see metaprogramming (`const_get`, `send`), dynamically built table names, or semantic coupling. |
| **Reason** | A full static analysis (parsing to AST, resolving constants) is significantly more work; text matching catches the realistic 90%. |
| **Impact** | A determined or unlucky developer can bypass the boundary check without noticing. |
| **Risk** | Medium — ADR-001's central assumption is that boundaries are mechanically enforced. Partial enforcement is a partial assumption. |
| **Effort** | Medium — move to Prism/RuboCop AST-based rules. |
| **Affected** | ADR-001's validity. |
| **Mitigation** | Limits are documented in the tool's README; the context map tracks per-context *extraction difficulty* as a lagging indicator of erosion the static check cannot see. |
| **Priority** | P3 |

### ~~TD-005~~ — No migration linter yet ✅ CLOSED 2026-08-10

| | |
|---|---|
| **Description** | [INV-11](02-architecture/architecture-constitution.md#inv-11--schema-changes-are-safe-for-rolling-deployment) (expand → migrate → contract) is currently enforced by review and by the N/N+1 CI job, not by a linter that rejects destructive DDL. |
| **Reason** | ADR-002 references `tools/migration-lint/`; it has not been built. |
| **Impact** | A destructive migration can reach CI before being caught, and the N/N+1 job only catches it if a test exercises the dropped column. |
| **Risk** | Medium-high — this is the classic cause of rolling-deploy outages. |
| **Effort** | Small-medium. |
| **Affected** | Every migration. |
| **Mitigation** | N/N+1 compatibility job; review checklist. |
| **Priority** | ~~P1~~ — **CLOSED**: [`tools/migration-lint`](../tools/migration-lint/README.md) enforces 6 rules (INV-11 rolling safety, INV-13 tenant column + index, INV-14 RLS), CI-blocking, with a self-test that also asserts it stays quiet on correct migrations and on `def down`. It found a real gap on its first run — see TD-008. |

### ~~TD-008~~ — `docs/06-data/` is nine declared documents and no files ✅ CLOSED 2026-08-10

| | |
|---|---|
| **Description** | `planned-docs.yml` declares nine data documents (`schema.md`, `database-architecture.md`, `partitioning.md`, `indexing-strategy.md`, `data-retention.md`, `caching.md`, `search.md`, `vector-storage.md`, `data-lineage.md`) for Phase 4. None exist. |
| **Reason** | Phase 4 was picked up starting with enforcement (migration-lint) and the domain schema; the documentation half has not been written. |
| **Impact** | `docs-lint`'s `stale-plan` rule turns all nine into **errors** the moment `current_phase` is bumped to 5, so this blocks the start of Phase 5 rather than degrading quietly. That is the mechanism working as designed. |
| **Risk** | Low now, blocking later — and deliberately so. |
| **Effort** | Medium. `schema.md` is the load-bearing one; several others describe subsystems that do not exist until Phases 6–10 and may be better re-declared for those phases than written thin now. |
| **Affected** | `tools/docs-lint/config.yml:current_phase`, `planned-docs.yml`. |
| **Mitigation** | None needed yet; the linter is the mitigation. |
| **Priority** | ~~P1~~ — **CLOSED**: [`schema.md`](06-data/schema.md) and [`database-architecture.md`](06-data/database-architecture.md) written; the other seven re-declared for the phase that builds what they describe (lineage → 6, search + vector storage → 10, retention → 13, caching + indexing + partitioning → 17). `current_phase` bumped to 5, which re-arms the ratchet rather than releasing it. |

### ~~TD-006~~ — `ApplicationRecord` has no default tenant scope yet ✅ CLOSED 2026-08-10

| | |
|---|---|
| **Description** | Isolation layer (b) — application-level default scoping — is not implemented; only the base class exists. |
| **Reason** | Phase 3 work. |
| **Impact** | Until then the isolation story rests on two layers, not three, and [FR-102](01-product/requirements.md#fr-102) is unmet. |
| **Risk** | **High if forgotten**, low while nothing stores tenant data. |
| **Effort** | Medium, including the isolation test suite that disables each layer in turn. |
| **Affected** | Every model. |
| **Mitigation** | No business tables exist yet, so there is nothing to leak. Phase 3 is gated on this. |
| **Priority** | ~~P1~~ — **CLOSED**: `TenantScopedRecord` implements layer (b); all three layers verified by `spec/isolation/tenant_isolation_spec.rb` (10 examples, mutation-tested) |

### TD-007 — MFA secrets use application-level encryption, not envelope encryption

| | |
|---|---|
| **Description** | `users.mfa_secret_ciphertext` is encrypted with `ActiveSupport::MessageEncryptor` under a key derived from the application's own secret. [INV-18](02-architecture/architecture-constitution.md#inv-18--secrets-never-leave-the-vault-in-plaintext-form-that-can-be-logged) requires envelope encryption with a real key manager. |
| **Reason** | Unresolved question Q1 (cloud KMS vs. Vault) is not decided, and blocking authentication on it would have blocked every phase after it. |
| **Impact** | A stolen database dump does not yield working second factors — that much holds. But an attacker who also has the application secret gets every MFA secret at once, and there is no per-tenant key hierarchy, so no crypto-shredding story for erasure (NFR-602). |
| **Risk** | Medium — requires compromise of two things rather than one, but the blast radius on that compromise is every user's second factor. |
| **Effort** | Small once Q1 is decided: the encrypt/decrypt pair is two methods in one module (`domains/identity/internal/mfa.rb`), deliberately isolated for this reason. |
| **Affected** | `users.mfa_secret_ciphertext`; the same key hierarchy will govern integration credentials (FR-602). |
| **Mitigation** | Encryption is confined to one module with no callers outside it, so the swap is local. The secret is never assigned to a loggable attribute and never leaves Identity. |
| **Priority** | P2 — due in Phase 13 with the rest of security hardening, and gated on Q1 |

### TD-009 — High-volume tables are unpartitioned, and partitioning is blocked on a security control

| | |
|---|---|
| **Description** | [ADR-002](11-decisions/ADR-002-database.md) planned `RANGE`-by-time partitioning for the append-only tables. [ADR-012](11-decisions/ADR-012-domain-schema.md) defers it: `event_store_events` permanently (partitioning is incompatible with its uniqueness guarantee), `outbox_messages` and `audit_records` to Phase 17. |
| **Reason** | A policy on a partitioned parent is **not** applied when a query names a partition directly — measured, not assumed. Combined with `db/roles.sql`'s default grants, every partition would need its own `ENABLE`/`FORCE`/policy, making the partition-creation job a security control. That job does not exist until Phase 12. |
| **Impact** | Converting a populated table to a partitioned one costs a maintenance window, and the cost grows with every row. This is a known future bill, deliberately preferred over an unverifiable isolation rule. |
| **Risk** | Low now (tables are empty); medium-high if neglected past the row counts in ADR-002's scalability table. |
| **Effort** | Medium: the partition job, its RLS application, and a test proving a directly-queried partition denies cross-tenant reads. |
| **Affected** | `outbox_messages`, `audit_records`. |
| **Mitigation** | Both tables have retention paths designed in (`published_at` reaping; `audit_chains` seals), so growth is bounded by policy rather than only by time. |
| **Priority** | P3 — revisit on the row-count trigger in ADR-012's reversal criteria, not on a date |

### TD-010 — `chunk_embeddings` and `usage_records` do not exist

| | |
|---|---|
| **Description** | Two declared tables were deliberately not created in Phase 4. Retrieval has documents and chunks but nowhere to store a vector; metering has budgets, reservations and rollups but no usage rows. |
| **Reason** | Each is shaped by an unresolved question — Q4 (embedding model and dimensionality) and Q5 (usage grain). A `vector(N)` column *is* the answer to Q4, fixed at DDL time. Writing either migration would answer a blocking question silently, which this project's own rule forbids. `pgvector` is also unavailable on the development machine. |
| **Impact** | Phase 10 (RAG) cannot complete without the first; Phase 9 (tool governance and cost) cannot complete without the second. |
| **Risk** | Low — the gap is one column in one table and one table respectively, not a missing subsystem. |
| **Effort** | Small once the questions are answered; each needs an ADR first. |
| **Affected** | [ADR-008](11-decisions/ADR-008-vector-database.md), Billing enforcement. |
| **Mitigation** | Everything either table depends on is built, so neither blocks other work today. |
| **Priority** | P2 — Q5 before Phase 9, Q4 before Phase 10 |

### TD-011 — `without_tenant_for_platform_operation` does not clear the database session variable

| | |
|---|---|
| **Description** | The helper clears isolation layer (c) — the Fiber-local tenant context — but not layer (a), the PostgreSQL `nexus.organization_id` session variable, because `SET LOCAL` is transaction-scoped and survives the release of a savepoint. |
| **Reason** | Found in Phase 5 while writing the ADR-013 specs. The name promises more than the implementation delivers. |
| **Impact** | None today: every platform-global table (`permissions`, `tenant_directory`, `event_type_registry`) has no RLS policy, so a stale variable changes nothing. A future platform operation reading an **RLS-protected** table from inside a tenant's transaction would silently see that one tenant's rows and believe it had seen all of them. |
| **Risk** | Low now, high when it bites — the failure is silent and looks like correct data. |
| **Effort** | Small, but it changes the semantics of a core isolation primitive: the helper would need to issue `SET LOCAL nexus.organization_id = ''` and restore it, which interacts with nested transactions. |
| **Affected** | `infrastructure/tenancy/context.rb`; every current and future caller. |
| **Mitigation** | Asserted by a test in `spec/organizations/tenant_spec.rb`, so the behaviour is documented and cannot regress unnoticed. An undocumented sharp edge is far more dangerous than a documented one. |
| **Priority** | P2 — before any platform operation reads an RLS-protected table |

---

## Deliberately accepted (not debt, decisions)

Recorded here so they are not repeatedly rediscovered and re-litigated as though they were oversights:

| Item | Why accepted | Revisit when |
|------|--------------|--------------|
| Pool-tier tenants share a PostgreSQL primary | The economics of self-serve depend on it ([ADR-009](11-decisions/ADR-009-multi-tenancy.md)) | A tenant needs isolation the pool cannot give → promote to dedicated |
| pgvector rather than a dedicated vector DB | RLS applies automatically; no second isolation model ([ADR-008](11-decisions/ADR-008-vector-database.md)) | The measured exit criteria in that ADR |
| We built a workflow engine | Workflows are tenant-authored data with platform-enforced governance ([ADR-006](11-decisions/ADR-006-workflow-engine.md)) | The reversal triggers in that ADR |
| No exactly-once delivery | It is not achievable with external side effects ([INV-06](02-architecture/architecture-constitution.md#inv-06--we-never-claim-exactly-once-delivery)) | Never |
| Two idioms in one codebase (CQRS and CRUD contexts) | Applied where read/write requirements genuinely conflict ([ADR-004](11-decisions/ADR-004-cqrs.md)) | If engineers can't tell which context they're in |
| Session revocation takes up to 15 minutes to stop an access token | The token carries identity only, so authority is still revoked instantly; buying zero-latency session kill costs a database read on every request ([ADR-011](11-decisions/ADR-011-authentication.md)) | The reversal criteria in that ADR — notably a verifier outside this process, or a contractual requirement for provable immediate termination |

---

## Closed

_None yet._
