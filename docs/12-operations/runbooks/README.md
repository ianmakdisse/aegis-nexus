# Runbooks

> **Status:** ⬜ index only. The runbooks themselves are Phase 12, declared in
> [`planned-docs.yml`](../../../tools/docs-lint/planned-docs.yml) and enforced by `docs-lint` — once
> `current_phase` passes 12, a missing one is a build error rather than a note.

[INV-24](../../02-architecture/architecture-constitution.md#inv-24--every-alert-has-a-runbook) is the reason
this directory exists: **an alert that cannot be acted upon is deleted or fixed, not tolerated.** A runbook is
therefore not documentation of a subsystem — it is the other half of an alert, and an alert without one is
incomplete by definition.

## Planned

| Runbook | Fires on | The question it answers |
|---------|----------|-------------------------|
| [Workflow stuck](workflow-stuck.md) | A run has not advanced past its expected duration | Is it `sleeping` on purpose, or is its lease not being reclaimed? |
| [Projection lag](projection-lag.md) | Projection lag SLI breached | Lag means stale (wait). Divergence means wrong (rebuild). Different problems, different actions. |
| [Tenant promotion](tenant-promotion.md) | Manual — a pool tenant needs dedicated placement | How to move a tenant without data loss or extended downtime (FR-104) |
| [AI provider degradation](ai-provider-degradation.md) | Provider error rate or latency breach | Which tier to shed, and how to degrade to humans rather than to silent wrong answers |

## What every runbook here must contain

Ordered so that someone paged at 3am reaches the action before the explanation:

1. **Symptom** — what the alert actually said.
2. **Blast radius** — who is affected right now, and whether data is at risk.
3. **First check** — one query or dashboard that distinguishes the likely causes.
4. **Actions**, most likely first, each with its own reversal.
5. **Escalation** — when to stop and who to wake.
6. **Aftermath** — what to capture while it is fresh, and which chaos test should have caught this.

## Two operational facts that predate any specific runbook

**Revoking a permission is immediate; revoking a session is not.** An access token remains valid for up to 15
minutes and is verified statelessly ([ADR-011](../../11-decisions/ADR-011-authentication.md)). To stop a
principal *right now*, remove their grant — authorization reads live state on every request. Killing the
session only stops the next refresh.

**Cross-tenant data is a security incident, not a bug.** Stop, preserve evidence, and escalate — do not
"fix the query". See [tenant isolation](../../08-security/tenant-isolation.md).
