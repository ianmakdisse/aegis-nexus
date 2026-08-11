# Architecture Changelog

> Every change to the architecture — not to the code. A commit that alters a boundary, a durability guarantee,
> a security property, a public contract, or a vendor dependency appears here
> ([INV-25](02-architecture/architecture-constitution.md#inv-25--significant-architectural-decisions-have-an-adr-written-before-implementation),
> [INV-26](02-architecture/architecture-constitution.md#inv-26--documentation-is-part-of-the-change)).
>
> Newest first. Never edit a past entry — append a correction instead.

---

## 2026-08-11 — Repository placed under version control at the Phase 4 baseline

**Author:** Platform

**Motivation:** The project reached Phase 4 with no repository. Every architectural claim in `/docs` was
verifiable only against a working directory that nothing preserved.

**Old architecture:** no version control.

**New architecture:** a local Git repository anchored by the annotated tag `phase-4-baseline`.

**What was deliberately *not* done:** history for Phases 0–4 was not reconstructed. Those phases happened
outside version control, and commits dated to them would be a fabricated record. The baseline is a snapshot,
decomposed into ~19 logical commits for reviewability, and it says so in
[project-state.md](00-start-here/project-state.md#version-control).

**Correction to the task as briefed:** this was requested as a *Phase 3* baseline. Verification against the
filesystem showed the tree at Phase 4 complete with Phase 5 in progress — 11 migrations to Phase 3's 4, 55
tables to 15, 12 ADRs, 3 CI checkers. Labelling it Phase 3 would have been precisely the false historical
claim the task existed to avoid, so the anchor is `phase-4-baseline`.

**Affected components:** none — no application code changed. `.gitignore` added.

**Security:** `config/master.key` is excluded; the encrypted credentials file is tracked, which is only safe
because the key is not. No API keys, private keys, or cloud credentials were found anywhere in the tree. The
local development role passwords in `db/roles.sql` and `spec/rails_helper.rb` are intentional setup values
for a local database, not secrets.

**Rollback:** deleting `.git/` returns the project to its previous state; no file contents were altered.

---

## 2026-08-10 — Core domain schema: 40 tables, a migration linter, and ADR-012

**Author:** Platform, Data, Security (Phase 4)

**Motivation:** Fifteen tables existed and fifty-four were declared. Every phase from 5 onward builds on tables
that did not exist, so the schema was the gate. TD-005 (the migration linter) was explicitly due "in Phase 4
when the first real migrations land", which made it the gate on the gate.

**Old architecture:** foundations only — organizations, identity, authorization. No event backbone, no
workflow engine tables, no agent runtime tables, no integrations, documents, notifications, billing or audit.

**New architecture:**

| Element | Decision |
|---------|----------|
| Enforcement first | `tools/migration-lint` — 6 rules, CI-blocking, self-tested. Closes TD-005 |
| Schema | 40 new tables across Events, Workflows, Agents, Integrations, Documents, Notifications, Billing, Audit |
| Partitioning | **Deferred** ([ADR-012](11-decisions/ADR-012-domain-schema.md)) — refines ADR-002 |
| INV-13 exemptions | New `ownership.yml:tenant_exempt` list, machine-checked in both directions |
| Conformance | `spec/isolation/schema_conformance_spec.rb` asserts RLS from `pg_class`/`pg_policies`, not from a list |
| RLS helper | `enable_tenant_rls!` — the linter's `missing-rls` rule names the fix rather than only the fault |

**Affected components:** every context's tables; `config/ownership.yml`; `config/application.rb` (migration
helper require); `README.md`.

**Contract change:** none. No published operation changed — these are tables, not contracts. The domain models
and runtimes that use them belong to Phases 5–10, and empty ActiveRecord classes would have been noise the
boundary checker cannot validate.

**Migration:** additive only. Six migrations, no destructive DDL, no backfill, applied to development and test.
`migration-lint` verifies all six are rolling-deploy safe.

**Rollback:** `rails db:rollback STEP=6`. Nothing reads these tables yet.

**Constitution:** no amendment. INV-13 and INV-14 are now enforced by two independent mechanisms — static
(`migration-lint`, at the diff) and live (the conformance spec, against the catalog). Neither subsumes the
other: a table created by a hand-run `execute` is invisible to the linter and obvious to the spec.

**Findings that changed the design:**

1. **A partition does not inherit its parent's RLS policy.** Measured on this schema's configuration: a
   non-owning tenant sees 0 rows through the partitioned parent and **1 row** querying the partition directly.
   `db/roles.sql` grants the app role access to every new table by default, so every partition would need its
   own `ENABLE`/`FORCE`/policy — making the partition-creation job a security control that does not exist
   until Phase 12. This is why partitioning was deferred rather than done at the cheapest moment.
2. **Time-partitioning is incompatible with the event store.** PostgreSQL requires a unique constraint on a
   partitioned table to include every partitioning column, and ADR-005's optimistic concurrency is
   `UNIQUE (organization_id, stream_id, sequence)`. `event_store_events` is therefore permanently unpartitioned
   by time — a refinement of ADR-002, not a deferral.
3. **The INV-13 exemption list did not exist.** `users` and `permissions` have carried no `organization_id`
   since Phase 3 and were enumerated nowhere machine-readable, because `platform_global` answers a different
   question ("no owner", not "no tenant"). The first run of `migration-lint` reported both. Now separated,
   justified per entry, and checked in both directions.

**Deliberately not built:** `chunk_embeddings` and `usage_records` (TD-010). Each is shaped by an unresolved
question — Q4 (embedding dimensionality, which a `vector(N)` column decides at DDL time) and Q5 (usage grain).
Writing either migration would have answered a blocking question silently. `pgvector` is also unavailable on
the development machine, recorded in the environment table.

---

## 2026-08-10 — Authentication flows implemented; ADR-011 accepted

**Author:** Platform, Security (Phase 3 remainder)

**Motivation:** The authorization evaluator landed earlier the same day and could not be reached by a real
request, because there was no way to become a principal. Authentication was the last foundation piece before
any HTTP surface could exist.

**Old architecture:** schema present (`users`, `sessions`, `service_identities`), no credential verification,
no token issuance, no principal type. `Identity`'s four declared public constants did not exist as code.

**New architecture:** [ADR-011](11-decisions/ADR-011-authentication.md), accepted before implementation per
INV-25.

| Element | Decision |
|---------|----------|
| Access tokens | Signed JWT, ≤ 15 min, carrying **identity only** — `sub`/`org`/`mbr`/`knd`/`scp`/`jti` and standard claims. An unrecognized claim is rejected, not ignored |
| Authorization data in tokens | **Forbidden.** Permissions are evaluated per request against live state, so ADR-010 Rule 1 holds unmodified |
| Refresh tokens | Opaque 256-bit, stored as SHA-256 digest, rotated every use, grouped by `family_id`; replay revokes the whole family |
| Login | Two steps: `Authenticate.password` identifies a global human, `IssueToken.for_user` binds them to one tenant and verifies membership |
| MFA | TOTP with a replay floor — codes from intervals at or before the last successful authentication are refused |
| Machine credentials | `nxs_<tenant>_<secret>`; the tenant segment is routing, so the digest lookup runs *inside* RLS instead of around it |
| Failure posture | One error, one message, for every reason; bcrypt runs against a dummy digest on unknown accounts so timing does not become the oracle instead |

**Affected components:** Identity (all published operations, newly implemented), Organizations
(`Membership` published as a query so Identity can resolve a membership without reading the table — INV-01),
`config/ownership.yml`, context map.

**Contract change:** `Identity` public surface gains `RegisterServiceIdentity` (FR-106 requires machine
principals to exist; nothing could create one). `Organizations::Membership` and
`Organizations::ProvisionOrganization` are now real code rather than declarations. Identity's declared tables
shrink from six to three: `credentials`, `mfa_factors` and `refresh_tokens` were declared in Phase 2 and never
created, because the schema puts the password digest and MFA secret on `users` and makes the session row
itself the refresh token. The register now matches the schema.

**Migration:** none. No schema change was required — the Phase 3 schema already anticipated this design,
including `sessions.family_id` and `users.last_authenticated_at`, both of which turned out to be load-bearing.

**Rollback:** removing the published operations reverts the system to "no principal can be constructed", which
is where it was this morning. No data migration to unwind.

**Constitution:** no amendment. INV-17 and INV-18 are now partially enforced by code; INV-18 is **not** fully
satisfied — MFA secrets use application-level encryption rather than envelope encryption, recorded as
[TD-007](technical-debt.md) and gated on unresolved question Q1.

**Defects found and fixed in passing:**

1. **Reuse detection revoked nothing.** `ReuseDetected` was raised from inside the same transaction that
   revoked the session family, so the rollback undid the revocations — the system detected the theft, logged
   it, raised, and left the attacker's session live. The error is now raised after the transaction commits.
   Found by a test asserting the *victim's* token was also dead, not by review.
2. **A `Principal` was not equal to itself after a round trip.** `IssueToken` built the principal before
   minting the token, so the returned principal had no `jti` while the one recovered from the token did. The
   token id is now generated once and used as both.
3. **A security test passed for the wrong reason.** The `alg=none` example forged a token with no `kid`, so it
   was rejected at key lookup rather than by the algorithm allowlist — it survived a mutation that added
   `"none"` to the permitted algorithms. The forged header now carries a valid `kid`, and the mutation fails.

---

## 2026-08-10 — Authorization evaluator implemented; Authorization's published contract widened

**Author:** Platform (Phase 4)

**Motivation:** `Authorize` had been a deliberate stub that raised on every call — correct as a fail-closed
placeholder, useless as a gate. Every context downstream of Phase 4 (workflows, agents, tools) is required by
INV-15/INV-20 to ask it a question before acting, so nothing further could be built honestly until it answered.

**Old architecture:** RBAC schema present (`roles`, `permissions`, `role_permissions`, `grants`, `policies`),
system roles seeded per tenant with no permissions attached, no evaluator.

**New architecture:**

| Element | Decision |
|---------|----------|
| Permission catalog | Platform-global vocabulary (`resource_type.action` + risk tier), installed by `PermissionCatalog.install!`, idempotent, never deleted from |
| Role templates | Built-in roles resolve to **explicit** `role_permissions` rows at seed time, not wildcards evaluated at request time |
| Evaluation order | catalog check → effective permission set (INV-16 intersection) → policy overlay → allow |
| ABAC overlay | Policies **refine only**. No `allow` policy can grant a permission the principal's roles do not carry |
| Policy precedence | Ascending `priority` (lower wins); first match decides; ties, unreadable matchers, and unknown clauses resolve to deny |
| Failure posture | Every evaluator error — missing tenant context, cross-tenant principal, DB fault, delegation cycle — returns `denied`, never raises past the caller |
| Bootstrap | `AssignRole` takes a required `authorized_by:`; the hatch is the literal `:system_bootstrap`, so every unauthorized grant is one grep away |

**Affected components:** Authorization (all published operations), Workflows (`Trigger` now authorizes
`workflows.trigger` and passes `definition_key` as an attribute rather than as the resource), Organizations
(provisioning now depends on the catalog being installed), `db/seeds.rb`.

**Contract change:** `Authorization`'s public surface grows from `[Authorize, PermissionSet, Policy,
SeedSystemRoles]` to add `PermissionCatalog` and `AssignRole` (`config/ownership.yml` + context map). The
`Authorize` signature changes from `(principal, action, resource)` to
`(principal, action, resource_type, attributes:)` — the resource *instance* is now an attribute, because
"which workflow may this principal start" is a policy question, not a separate permission.

**Migration:** `rails db:seed` installs the catalog. Tenants provisioned before this change have system roles
with no attached permissions; re-running `SeedSystemRoles` inside their tenant context reconciles them, and is
idempotent. No tenant had been provisioned outside a test database, so no production backfill exists.

**Rollback:** the evaluator can be reverted to the raising stub without a schema change; the catalog rows are
inert without it.

**Constitution:** no amendment. INV-15, INV-16 and ADR-010 Rule 1 are now enforced by code and tests rather
than by intent; the enforcement-summary row for INV-15/16/20 is satisfied for the human and service cases and
still pending for the tool case (Phase 9).

**Defect found and fixed in passing:** `SeedSystemRoles` used `create_or_find_by!`, which rescues the
database's `RecordNotUnique`. `Role` validates key uniqueness in Ruby, so the second run raised
`RecordInvalid` before any INSERT — the rescue could never fire and the "idempotent" seed was not idempotent.
Found by writing the test that asserted the documented property.

---

## 2026-08-09 — Foundation: Constitution ratified, ADR-001…010 accepted

**Author:** Architecture (Phase 1)
**Motivation:** Establish the invariants and the ten load-bearing decisions *before* implementation, so that
code can be reviewed against a stated position rather than against taste.

**Old architecture:** none (greenfield).

**New architecture:**

| Area | Decision |
|------|----------|
| Style | Modular monolith, independently scaled process roles ([ADR-001](11-decisions/ADR-001-architecture-style.md)) |
| Datastore | PostgreSQL authoritative for all business state ([ADR-002](11-decisions/ADR-002-database.md)) |
| Messaging | Kafka for the event log; PostgreSQL job queue for scheduling; Redis pub/sub for live push ([ADR-003](11-decisions/ADR-003-event-bus.md)) |
| Read models | CQRS per context, not globally ([ADR-004](11-decisions/ADR-004-cqrs.md)) |
| History | Event sourcing for `WorkflowRun`, `AgentExecution`, `ApprovalRequest`, `AuditTrail` only ([ADR-005](11-decisions/ADR-005-event-sourcing.md)) |
| Execution | Own durable workflow interpreter on PostgreSQL ([ADR-006](11-decisions/ADR-006-workflow-engine.md)) |
| AI | Own the agent loop; provider port; four routing tiers ([ADR-007](11-decisions/ADR-007-ai-runtime.md)) |
| Vectors | pgvector behind a port, with measured exit criteria ([ADR-008](11-decisions/ADR-008-vector-database.md)) |
| Tenancy | Hybrid: RLS pool + database-per-tenant dedicated tier ([ADR-009](11-decisions/ADR-009-multi-tenancy.md)) |
| Consistency | Declared class per operation; anything that can deny reads strong state ([ADR-010](11-decisions/ADR-010-consistency-model.md)) |

**Affected components:** all (foundational).

**Migration:** n/a.

**Rollback:** n/a — but note that ADR-006 and ADR-008 carry explicit reversal criteria, and ADR-003's
transport port is what would make a broker change tractable.

**Constitution:** v1.0 ratified, invariants INV-01 … INV-26.

**Notable tension recorded rather than resolved:** ADR-006 (build the workflow engine) is the highest-risk
decision in the set. Its reversal criteria are pre-committed precisely because the team expects this to be the
decision most likely to be revisited.

---

## Entry template

```markdown
## YYYY-MM-DD — <short title>

**Author:**
**Motivation:** what changed in the world that made the old architecture wrong
**Old architecture:**
**New architecture:**
**Affected components:**
**Migration:** how existing data/traffic/state moves
**Rollback:** how to get back, and the point after which you cannot
**Related ADRs:**
**Constitution:** amended? which invariants?
```
