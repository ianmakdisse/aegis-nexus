# Personas

> Personas exist to justify features. Every requirement in [requirements.md](requirements.md) names the persona
> it serves; a requirement with no persona is a requirement we should not build.

---

## P-1 — Priya, Operations Lead ("the primary user")

**Context.** Runs a 12-person ops team at a retailer processing ~40k orders/day. Lives in a browser with 9 tabs open.

**Goals**
- See what is happening *right now* across systems in one place.
- Automate the 80% of decisions that are mechanical, without losing control of the 20% that are not.
- Never be the reason an order sat untouched for six hours.

**Frustrations**
- "Automation" that silently stops working and nobody notices for a week.
- Being asked to approve something with no context about *why* it needs approval.

**What the platform must give her**
- The command center ([FR-901](requirements.md#fr-901)), real-time updates ([FR-905](requirements.md#fr-905)),
  approval inbox with full context ([FR-407](requirements.md#fr-407)), and workflow run timelines
  ([FR-308](requirements.md#fr-308)).

**Her failure mode if we get it wrong:** she builds a shadow spreadsheet and stops trusting the platform.

---

## P-2 — Marco, Automation Engineer / Integrator

**Context.** Semi-technical. Builds and maintains the workflows. Comfortable with JSON and HTTP, not with Kubernetes.

**Goals**
- Compose workflows visually, test them safely, version them, and roll back a bad change in seconds.
- Connect a new SaaS tool in under an hour without filing a ticket.

**Frustrations**
- Changing a workflow and silently breaking 4,000 in-flight executions.
- Debugging an automation that "just didn't run" with no trace.

**What the platform must give him**
- Visual builder ([FR-903](requirements.md#fr-903)), workflow versioning with in-flight compatibility
  ([FR-305](requirements.md#fr-305)), dry-run/simulation ([FR-310](requirements.md#fr-310)), integration
  marketplace ([FR-601](requirements.md#fr-601)), and per-step execution traces ([FR-308](requirements.md#fr-308)).

---

## P-3 — Dr. Chen, Platform / SRE Engineer

**Context.** Owns uptime for the platform itself across four regions. Carries the pager.

**Goals**
- Diagnose any incident from telemetry without SSH-ing into a box.
- Know the blast radius of any dependency failure *before* it fails.

**Frustrations**
- Systems where "async" means "unobservable".
- Recovery procedures that exist only in a senior engineer's head.

**What the platform must give her**
- OTel traces spanning sync + async boundaries ([NFR-501](requirements.md#nfr-501)), correlation IDs everywhere,
  a [failure matrix](../02-architecture/failure-domains.md), tested [runbooks](../12-operations/runbooks/),
  and [chaos experiments](../12-operations/chaos-engineering.md) that validate the claims.

---

## P-4 — Sofia, CISO / Compliance Officer

**Context.** Signs off on whether this platform may touch customer PII and financial data. Answers to auditors.

**Goals**
- Prove tenant isolation holds. Prove no agent exceeded its authority. Reconstruct any decision on demand.

**Frustrations**
- "The AI decided" as an explanation.
- Audit logs that are mutable, or that lack the inputs that produced the decision.

**What the platform must give her**
- Immutable, hash-chained audit trail ([FR-801](requirements.md#fr-801)), full AI execution records
  ([FR-405](requirements.md#fr-405)), permission-boundary enforcement on tools ([FR-403](requirements.md#fr-403)),
  the [threat model](../08-security/threat-model.md), and [tenant isolation](../08-security/tenant-isolation.md)
  with its enforcement layers enumerated.

---

## P-5 — Rafael, CFO / FinOps

**Context.** Approved the AI budget. Watches it monthly and is nervous.

**Goals**
- Know cost per tenant, per workflow, per agent — and be protected from a runaway loop.

**Frustrations**
- A single misconfigured agent producing a five-figure invoice overnight.

**What the platform must give him**
- Hierarchical budgets with hard enforcement ([FR-702](requirements.md#fr-702)), cost attribution to every
  unit of work ([FR-701](requirements.md#fr-701)), anomaly detection ([FR-704](requirements.md#fr-704)),
  and the financial agent that can investigate a spike ([FR-408](requirements.md#fr-408)).

---

## P-6 — The Agent (a non-human principal)

**Context.** Not a user, but a *principal* in the security model. Deserves a persona because designing for it
explicitly is what prevents treating it as trusted code.

**Capabilities it wants:** read data, call tools, spawn sub-work, remember across runs.

**What the platform must impose on it:** an identity ([FR-401](requirements.md#fr-401)), a permission set
strictly ⊆ its invoking principal's ([FR-403](requirements.md#fr-403)), budgets and step ceilings
([FR-406](requirements.md#fr-406)), and a full record of everything it did ([FR-405](requirements.md#fr-405)).

> **Design rule that follows from this persona:** the agent runtime treats model output as *untrusted user input*,
> never as instructions. See [AI security](../08-security/ai-security.md).

---

## P-7 — Ana, New Engineer (day one)

**Context.** Just joined. Competent, knows nothing about this system.

**Goal:** understand the system well enough to ship a safe change within a week.

**What the platform must give her:** `/docs` — specifically [start here](../00-start-here/README.md),
the [system map](../00-start-here/system-map.md), and the *Understanding This System* sections that every
complex subsystem carries ([documentation contract](../00-start-here/README.md#the-documentation-contract)).

> Ana is the persona for [Section 53 of the brief](../00-start-here/documentation-audit.md): if she cannot
> answer the twenty listed questions using only `/docs`, the documentation has a defect and it is tracked
> like any other defect.
