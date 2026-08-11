# Identity

> Owns principals: who is making a request, and how we know.
>
> **Status:** ✅ password + TOTP authentication, session rotation, and machine credentials implemented and
> tested (Phase 3 complete). OIDC/SAML SSO — the enterprise half of [FR-105](../../01-product/requirements.md#fr-105)
> — is Phase 13 and sits behind the same `Authenticate` contract.

## Understanding This System

**Level 1 — Beginner.** Identity answers "who are you?" and nothing else. It does *not* answer "what may you
do?" — that is [Authorization](../authorization/README.md). Keeping those separate is why an AI agent can be a
first-class actor without being a person.

**Level 2 — Engineer.** Three kinds of principal, all first-class:

| Principal | Table | Authenticates with |
|-----------|-------|--------------------|
| User (human) | `users` | Password + TOTP, or OIDC/SAML for enterprise |
| Service | `service_identities` (`kind: service`) | Token, scoped, expiring |
| Agent | `service_identities` (`kind: agent`) | Token, scoped, expiring |

Agents and services get their own identities because *"the app did it"* is not an acceptable audit answer
(FR-106), and shared service accounts make least privilege impossible.

`users` is **global**, not tenant-scoped: one person may belong to several organizations. Duplicating accounts
per tenant would break SSO identity and make "who is this human" unanswerable. Access to a user is mediated by
`memberships`, which *is* tenant-scoped and RLS-protected.

**Level 3 — Expert.** Sessions carry a `family_id` for refresh-token reuse detection (FR-109): a rotated token
presented a second time means the token was stolen, so the entire family is revoked rather than just the
replayed token. Access tokens are ≤ 15 minutes precisely so that revocation latency is bounded without
consulting the database on every request — and authorization decisions are never cached beyond a request
([ADR-010](../../11-decisions/ADR-010-consistency-model.md) Rule 1), so a revoked *permission* takes effect
immediately even while a token remains valid.

`mfa_secret_ciphertext` is encrypted (INV-18) and never appears in logs, traces, or prompts. It is not yet
envelope-encrypted with a real key manager — see [TD-007](../../technical-debt.md).

## Logging in is two steps, and that is the design

```
Authenticate.password(email:, password:, mfa_code:)   → VerifiedUser   ← global, no tenant context
IssueToken.for_user(user_id:, organization_id:)       → Result         ← one tenant, membership verified
```

Verifying a credential proves a *person exists*. It says nothing about whether they belong to the organization
they are asking for. Conflating the two is how a valid login becomes access to somebody else's tenant, so
`Authenticate` deliberately returns a `VerifiedUser` and not a `Principal` — a principal is authority inside
one tenant, and which tenant has not been decided at that point.

This also means credential checking never runs inside the wrong tenant's context, or worse, inside none at all
while touching tenant-scoped rows.

**There is no "list my organizations" query, and there cannot be one.** Answering it means reading
`memberships` across tenants, which RLS forbids by construction. Tenant selection comes from the request
(subdomain or slug) and is *verified* against a membership by `IssueToken` — which is the safe direction.

## What the access token carries

Identity. Not authority. See [ADR-011](../../11-decisions/ADR-011-authentication.md) for the full argument.

| Claim | Meaning |
|-------|---------|
| `sub` | User id, or service identity id |
| `org` | Tenant |
| `mbr` | Membership (null for machines) |
| `knd` | `user` \| `service` \| `agent` |
| `scp` | Scopes — a ceiling that narrows, never a grant |
| `jti` | Token id, so one credential can be traced through the audit log |
| `iss` `aud` `iat` `nbf` `exp` | Standard; `exp` ≤ 15 min (FR-109) |

A claim outside that list is **rejected**, not ignored, so a token minted by a future version cannot smuggle a
field this version does not understand. There is no `perms` claim and adding one is a defect — a permission in
a token cannot be revoked, which is the entire reason the evaluator is consulted per request instead.

`scp` is the exception that proves the rule: it can only ever narrow, and it is intersected like any other
narrowing input ([INV-16](../../02-architecture/architecture-constitution.md#inv-16--delegated-authority-only-narrows)).

## Rotation and reuse detection

Refresh tokens are opaque 256-bit values stored only as SHA-256 digests. Every refresh invalidates the token
presented and issues a new one in the same `family_id`, so a refresh token is usable exactly once.

A rotated token presented a second time means two parties hold it, and there is no way to tell which one is
the thief. So the whole family is revoked — the legitimate user is logged out too. That is the correct bias
when the alternative is leaving an attacker with a live session.

> **The revocation must survive the error.** The first implementation raised `ReuseDetected` from inside the
> same transaction that performed the revocations, so the rollback undid them: the system detected the theft,
> reported it, and left the attacker's session live. The error is now raised *after* the transaction commits.
> This was found by a test asserting the victim's token was dead too, not by review.

## Machine credentials

Format: `nxs_<tenant>_<secret>`. The tenant segment is **routing, not authority**.

`service_identities` is RLS-protected, so a lookup by digest returns nothing unless a tenant context is
already open — but the whole point of authenticating is that we do not yet know who is calling. Rather than
disabling isolation to authenticate, the credential names its own tenant and the lookup happens inside that
tenant's context. Forging the segment simply opens a context where the presented secret matches nothing.

What this buys: authentication never runs unscoped, a stolen token cannot probe other tenants, and the prefix
makes the credential greppable in logs and detectable by secret scanners — a credential nobody can recognize
is one nobody can find after it leaks.

A registered identity holds **no authority** until a role is granted through `Authorization::AssignRole`.
Creating an actor is not a way to create power.

## Failure posture

Every authentication failure raises the same error with the same message. Not "no such user", not "wrong
password", not "MFA required" — those are an account enumeration oracle, and the helpful version is how a
leaked email list becomes a target list. The reason is attached for the audit log and never rendered.

The same applies to timing: bcrypt runs against a fixed dummy digest even when no user matched, because
returning early on "no such account" is the same oracle delivered by a stopwatch.

TOTP codes are additionally rejected if they come from an interval at or before the user's last successful
authentication. Without that floor, a code observed in transit is replayable for the rest of its 30-second
step — which is the difference between MFA and the appearance of MFA.

## Published contract

`Identity::Authenticate` · `Identity::Principal` · `Identity::IssueToken` · `Identity::RevokeToken` ·
`Identity::RegisterServiceIdentity`

`Principal` carries **identifiers only** — no password digest, no token, no MFA secret, no email. Credential
material never leaves this context, so no other context can leak what it was never given (INV-18).

Authorization accepts a principal structurally (`organization_id` plus exactly one subject id, optionally
`acting_for`) and never names this class, because it is not permitted to call Identity synchronously and does
not need to.

## Tables

`users` (global) · `sessions` (tenant-scoped, RLS) · `service_identities` (tenant-scoped, RLS)

The Phase 2 register also declared `credentials`, `mfa_factors` and `refresh_tokens`. They were never created:
the password digest and MFA secret live on `users`, and the session row *is* the refresh token. Three tables
for what is one row each was the plan; the schema is better, and `config/ownership.yml` now says so.

## Tests

`spec/identity/` — 59 examples. Proven non-vacuous by mutation: removing the TOTP replay floor, permitting
`alg=none`, removing reuse detection, and removing the membership check each fail 1, 1, 2 and 3 examples
respectively.

## Related
[ADR-011](../../11-decisions/ADR-011-authentication.md) · [Authorization](../authorization/README.md) ·
[Organizations](../organizations/README.md) · [Authentication](../../08-security/authentication.md)
