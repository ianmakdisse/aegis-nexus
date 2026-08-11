# ADR-011 — Stateless access tokens carrying identity only; permissions are never in the token

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-10 |
| **Deciders** | Platform, Security |
| **Supersedes** | — |

---

## Context

Authentication is the last foundation piece before anything else in the platform can be reached by a real
request. The authorization evaluator exists and is enforced, but nothing can call it: there is no principal,
because there is no way to become one.

The decision looks routine and is not, because two of this system's stated positions pull in opposite
directions:

- **NFR-101** puts API latency at p95 < 150 ms. A database round-trip to a session table on every single
  request — including every agent tool call and every workflow step that acts as a principal — is a fixed cost
  on the hottest path in the system, paid by every context.
- **[ADR-010](ADR-010-consistency-model.md) Rule 1** and
  **[INV-15](../02-architecture/architecture-constitution.md#inv-15--authorization-is-deny-by-default-and-centrally-evaluated)**
  say anything that can *deny* an action reads strongly consistent state. The [authorization
  evaluator](../03-domains/authorization/README.md) has no cache at all, deliberately.

The industry's default answer to the first force — a JWT carrying the caller's roles and permissions — is
precisely what the second force forbids. That answer is why "we revoked their access but they kept working for
another hour" is such a common incident, and it would quietly repeal the invariant this platform spent Phase 4
enforcing.

What breaks if we get it wrong in each direction:

- **Too stateless** (permissions in the token): a revoked permission is honored until the token expires. There
  is no mechanism to take it back, because the whole point of the design was not to look anything up. The blast
  radius is every permission the token carries, for the token's full lifetime.
- **Too stateful** (a session lookup for everything): the session table becomes the most-read row in the
  system, every context inherits its availability, and the p95 budget is spent before the request reaches a
  controller. Worse, the obvious fix is to cache sessions in Redis — which puts authentication state in a store
  [INV-08](../02-architecture/architecture-constitution.md#inv-08--redis-is-never-the-source-of-truth-for-durable-business-state)
  says must never be authoritative.

A second, quieter tension: `users` is platform-global (one human, many organizations) while `sessions` is
tenant-scoped and RLS-protected. So "log in" is not one operation. Identifying a human and establishing their
authority inside one tenant are different questions with different isolation properties, and conflating them is
how a credential check ends up running outside a tenant context.

## Requirements driving this decision

| ID | Requirement |
|----|-------------|
| [FR-105](../01-product/requirements.md#fr-105) | Human authentication: password + TOTP MFA, OIDC/SAML SSO for enterprise |
| [FR-106](../01-product/requirements.md#fr-106) | Non-human identity for services and agents, with their own credentials and audit identity |
| [FR-109](../01-product/requirements.md#fr-109) | Access tokens ≤ 15 min with explicit audience and scope; refresh rotation with reuse detection |
| [NFR-101](../01-product/requirements.md#nfr-101) | API latency p95 < 150 ms |
| [INV-15](../02-architecture/architecture-constitution.md#inv-15--authorization-is-deny-by-default-and-centrally-evaluated) | Deny-by-default, centrally evaluated authorization |
| [INV-16](../02-architecture/architecture-constitution.md#inv-16--delegated-authority-only-narrows) | Delegated authority only narrows |
| [INV-17](../02-architecture/architecture-constitution.md#inv-17--no-implicit-trust-between-services) | No implicit trust between services; network position is not a credential |
| [INV-18](../02-architecture/architecture-constitution.md#inv-18--secrets-never-leave-the-vault-in-plaintext-form-that-can-be-logged) | Secrets never appear in logs, traces, events, or prompts |

## Considered alternatives

### A. Stateful opaque sessions — every request resolves a session row

The classic server-side session. The client holds an opaque identifier; the server looks it up on each request.

**Advantages** — Revocation is instant and total, which is the single most valuable property an
authentication system can have. There is no token cryptography to get wrong, no key rotation, no clock-skew
class of bugs, and no risk of a claim being trusted after it stops being true. The mental model fits in one
sentence, which matters for a security control that every engineer will touch.

**Disadvantages** — A database read on the critical path of every request in the system, including internal
principal resolution for agents and workflow steps. At the platform's target scale this is the highest-QPS
query by a wide margin, and it is a *serial* dependency: nothing else in the request can start until it
returns. It also concentrates availability — a degraded sessions table degrades authentication for every
tenant simultaneously, which is a failure domain the rest of the architecture works hard to avoid. The
standard remedy is a Redis session cache, which INV-08 forbids from being authoritative and which would make
revocation eventually-consistent anyway, quietly re-creating alternative B's problem with more moving parts.

### B. JWT carrying roles and permissions — the industry default

The access token asserts what the caller may do. Authorization becomes signature verification.

**Advantages** — Genuinely the fastest possible design: zero datastore reads for both authentication and
authorization, trivially horizontally scalable, and it works unchanged if a context is later extracted into
its own service (an explicitly preserved option under [ADR-001](ADR-001-architecture-style.md)). It is also
what most engineers expect, which has real value: a design that surprises people gets worked around.

**Disadvantages** — It repeals ADR-010 Rule 1. A permission revoked at 10:00 is honored until the token
expires, and there is no mechanism to intervene, because avoiding the lookup *is* the design. Shortening
expiry narrows the window but never closes it, and every reduction moves cost onto the refresh path until the
system is stateful again with worse ergonomics. It also puts authorization logic on the token issuer, where it
is computed once, ahead of time, for a request that has not happened — the opposite of the evaluator built in
Phase 4, whose ABAC overlay depends on per-request attributes that cannot be known at issue time. Adopting
this would mean deleting `Authorization::Policy` and amending the Constitution.

### C. *(chosen)* Stateless access token carrying **identity only**; permissions read fresh on every decision

The access token asserts *who* the caller is — subject, tenant, membership, kind, audience, scope, expiry — and
nothing about what they may do. Authorization is evaluated per request, from the database, exactly as it is
today.

**Advantages** — Splits the problem along the line where the two forces actually differ. Identity is slow-moving
and cheap to be briefly stale about; permissions are fast-moving and expensive to be stale about. Verification
is a signature check with no I/O, so the p95 budget is preserved on the hot path, while every *decision*
still reads strong state and ADR-010 Rule 1 holds unmodified. Refresh becomes the natural revocation
checkpoint: it is stateful, infrequent (≤ 4/hour/session), and already touching the database.

**Disadvantages** — A deactivated user or a revoked session keeps a *usable identity* until the access token
expires — bounded at 15 minutes, not zero. Deleting a user does not instantly stop in-flight requests. It
introduces signing-key management, which the alternatives do not have, and a class of bugs (skew, `kid`
rotation, audience confusion) that stateful sessions simply cannot produce. It is also strictly more code than
alternative A.

## Decision

Access tokens are short-lived signed JWTs that carry **identity only** — `sub` (user or service identity),
`org`, `mbr` (membership), `kind`, `aud`, `scope`, `jti`, `exp` ≤ 15 minutes — and never carry roles,
permissions, or any authorization result. Every authorization decision continues to be evaluated per request
by `Authorization::Authorize` against current database state, with no cache. Refresh tokens are opaque
256-bit random values stored only as SHA-256 digests, rotated on every use, and grouped by `family_id`: a
refresh token presented twice means it was stolen, so the entire family is revoked rather than the replayed
token alone. Human authentication is two-step — credentials identify a globally-scoped user, then a separate
step establishes a tenant-scoped session for one organization — and service and agent principals authenticate
by bearer token compared in constant time against a stored digest.

## Why

The asymmetry is in how expensive each kind of staleness is to recover from.

Being wrong about **identity** for up to 15 minutes means a user whose account was just disabled can finish
what they were already doing. That is bounded, observable in the audit trail, and correctable — and every
action they take in that window is still evaluated against *current* permissions, so revoking their grants
stops them immediately even while their token remains syntactically valid. The damage is capped by the shorter
of two clocks, and we control both.

Being wrong about **permissions** means a revoked capability is honored with no upper bound on damage and no
intervention available. There is no equivalent second clock, because the whole design of alternative B is the
absence of one.

So we accept staleness in the direction that is cheap and bounded, and refuse it in the direction that is not.
This is the same trade the rest of the platform makes — derived data may lag, authoritative decisions may not.

## Consequences

**What becomes true:**

- A verified access token is proof of *identity*, never of *authority*. Any code that reads a permission from a
  token is a defect, and the token has no permission field for it to read.
- Revocation has two latencies, and they are different on purpose: permission revocation is immediate;
  session revocation takes effect at the next refresh, ≤ 15 minutes.
- Authentication and tenancy are separable. Identifying a human happens outside any tenant context; everything
  after that happens inside exactly one.
- `Identity::Principal` is the value object every other context receives. It satisfies the structural contract
  Authorization already expects (`organization_id` plus exactly one subject id, optionally `acting_for`), so
  the agent delegation path from INV-16 works with real principals without Authorization ever naming this
  context's constants.

**Obligations this creates:**

| Obligation | When |
|-----------|------|
| Signing keys move to the resolved secrets manager (unresolved question Q1) | Phase 13 |
| MFA secrets move from application-level encryption to envelope encryption with a real KMS | Phase 13 |
| OIDC/SAML SSO (the enterprise half of FR-105) added behind the same `Authenticate` contract | Phase 13 |
| Account lockout / credential-stuffing defense beyond edge rate limiting | Phase 13 |
| Every authenticated action emits an audit record | Phase 10 (Audit context) |
| Token issuance and refresh emit governance events | Phase 5 (Events context) |

## Failure modes

| Failure mode | Detection | Impact | Mitigation |
|--------------|-----------|--------|------------|
| Refresh token stolen and replayed | Second presentation of a rotated digest within a family | Attacker holds a valid session | Entire family revoked on reuse; both legitimate user and attacker are logged out, which is the correct bias |
| Access token stolen | Not detectable by construction — it is a bearer credential | Attacker acts as the user for ≤ 15 min, within *current* permissions | Short expiry; permissions still evaluated fresh, so revoking grants stops the attacker immediately |
| Signing key leaked | Key material appearing outside the vault; anomalous `jti` volume | Attacker mints arbitrary identities | `kid` in the header allows rotation without invalidating verification of in-flight tokens; rotation runbook (Phase 13) |
| Clock skew between issuer and verifier | Token rejected as expired or not-yet-valid at low rates | Spurious 401s | Single process signs and verifies today; a small leeway is applied, and skew becomes a real risk only when a second verifier exists — which is also this ADR's reversal criterion |
| User deactivated but token still valid | Audit trail shows activity after deactivation | ≤ 15 min of continued access | Permission revocation is immediate and independent; refresh re-checks user status |
| MFA secret exposed in a log or trace | Redaction test in the telemetry suite (INV-18) | TOTP bypass for that user | Secret is encrypted at rest and never assigned to a loggable attribute; `filter_parameter_logging` covers the parameter names |
| Password digest exposed via an error or serializer | Review; serializer tests | Offline cracking | bcrypt cost 12; `password_digest` is never exposed by a published contract — `Principal` carries no credential material |

## Operational impact

**Adds:** a signing key that must exist in every environment and be rotatable; a `kid`-aware rotation
procedure; a metric for refresh-reuse detections, which is a security signal rather than a performance one and
should page rather than graph.

**Removes:** the need for a session cache, a cache-invalidation path, and the operational question of what to
do when Redis and PostgreSQL disagree about who is logged in. There is no such question in this design, because
Redis is not involved in authentication at all.

**On-call must know:** revoking a *permission* is immediate; revoking a *session* is not. An incident that
requires stopping a principal right now is a permission action, not a session action. This is the single most
important operational consequence of this ADR and belongs in the incident runbook.

## Cost impact

Marginal cost is near zero and *negative* relative to alternative A: the design removes one database read from
every authenticated request in the system. At target scale that is the difference between the sessions table
being the highest-QPS object in the database and it being touched only on login and refresh — roughly four
reads per session-hour instead of one per request. Fixed cost is the signing key's storage in whichever
secrets manager Q1 selects, which is negligible and already required for other credential material.

## Security impact

**Better:** permissions cannot go stale, which is the property that actually matters during an incident.
Credential material never leaves this context — `Principal` carries identifiers only, so no other context can
leak what it does not receive. Refresh reuse detection turns a stolen token from a silent compromise into an
alarm. Constant-time digest comparison closes the timing channel on service tokens. Password and token digests
are one-way, so a database read alone does not yield a usable credential.

**Worse:** a bearer access token is, unavoidably, a bearer credential — anyone holding it is the user for up to
15 minutes, and unlike a session identifier we cannot revoke it mid-flight. We have added signing-key
management, and a leaked key is a more severe compromise than a leaked session row because it mints identities
rather than reusing one. Stateless verification also means a token is valid in any region that trusts the key,
which interacts with data-residency pinning (NFR-601) and must be re-examined in Phase 15 when multi-region
lands.

**Deliberately not solved here:** account lockout and credential-stuffing defense are edge concerns
(rack-attack, FR-604) and are not part of this decision. Naming that gap is the point; an ADR that implied
authentication was "done" would be the more dangerous document.

## Scalability impact

Verification is CPU-only and scales horizontally with the API role — there is no shared component to
contend on. The stateful parts (login, refresh, revoke) scale with *sessions*, not with requests, which is
three to four orders of magnitude less traffic.

Where it stops working: when a component outside this process must verify a token. A symmetric key cannot be
distributed to an edge proxy or an extracted service without giving every holder the ability to *mint*
tokens. That is the boundary of this design, and the next move is stated below rather than discovered later.

## Reversal criteria

We revisit this decision when any of the following becomes true:

| Trigger | Move |
|---------|------|
| Any verifier exists outside the control-plane process (edge gateway, extracted context per ADR-001, partner service) | Switch to asymmetric signing (EdDSA), publish a JWKS endpoint; the `kid` header exists so this does not invalidate in-flight tokens |
| A regulator or enterprise contract requires provable immediate session termination | Add a revocation check on the hot path for the affected tenants only — the dedicated tier ([ADR-009](ADR-009-multi-tenancy.md)) already provides the per-tenant seam to do this without imposing it on everyone |
| Refresh-reuse detections exceed a low single-digit monthly rate not explained by legitimate client races | The rotation scheme is wrong, not the storage; re-examine client behavior before weakening detection |
| Measured p95 shows session lookups were never the bottleneck alternative A was rejected for | Reconsider A on its merits — its revocation properties are genuinely better, and this ADR's case rests on a cost that would then be shown not to exist |

The last row is deliberate. This decision's argument depends on a performance claim that has not yet been
measured on this system, only reasoned about. If the measurement contradicts it, the simpler design wins.

## Related decisions

[ADR-009](ADR-009-multi-tenancy.md) — sessions are tenant-scoped because tenancy is a database-enforced
property, not a claim · [ADR-010](ADR-010-consistency-model.md) — Rule 1 is what rejects alternative B ·
[ADR-001](ADR-001-architecture-style.md) — the extraction option is what makes the reversal criterion real

## Related code

- `apps/control-plane/domains/identity/principal.rb`
- `apps/control-plane/domains/identity/authenticate.rb`
- `apps/control-plane/domains/identity/issue_token.rb`
- `apps/control-plane/domains/identity/revoke_token.rb`
- `apps/control-plane/domains/identity/internal/access_token.rb`
- `apps/control-plane/domains/identity/internal/token_digest.rb`

## Related diagrams

[Request flow](../02-architecture/request-flow.md) · [Context map](../02-architecture/context-map.md)
