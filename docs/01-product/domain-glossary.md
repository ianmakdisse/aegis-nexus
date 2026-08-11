# Domain Glossary (Ubiquitous Language)

> **Scope:** business-domain vocabulary. Platform/infrastructure terms live in
> [00-start-here/glossary.md](../00-start-here/glossary.md).
>
> **Rule:** these words mean exactly this in conversation, in code, in the database, and in the API.
> If code disagrees with this file, one of them is a bug — file it in
> [technical-debt.md](../technical-debt.md) rather than quietly diverging.

---

## Tenancy & people

| Term | Definition | Deliberately NOT |
|------|-----------|------------------|
| **Organization** | The tenant. The root of all data ownership and billing. Identified by `organization_id` everywhere. | Not "company", not "account", not "workspace" — pick one word and never alternate |
| **Membership** | The link between a User and an Organization, carrying roles. A user may belong to many organizations. | Not a "user role" — roles are held *through* a membership, never globally |
| **Team** | A named subset of memberships used for assignment and routing. | Not a permission boundary (that's roles/policies) |
| **Principal** | Anything that can act: user, service, or agent. Every audit record names one. | Not synonymous with "user" |
| **Actor** | The principal responsible for a specific action, as recorded in audit. | |
| **On-behalf-of** | An agent or service acting under a user's authority, recorded as `actor=agent, on_behalf_of=user`. Permissions are the **intersection**, never the union. | Never "impersonation" |

## Events

| Term | Definition | Deliberately NOT |
|------|-----------|------------------|
| **Integration Event** | A fact received from or sent to an external system. Untrusted until validated. | Not a domain event |
| **Domain Event** | A fact produced by our own domain logic, in the past tense (`OrderFlagged`), immutable. | Never a command in disguise |
| **Command** | A request to change state. May be rejected. Imperative (`FlagOrder`). | Not an event |
| **Ingested Event** | The durable record of raw inbound data, stored before any processing. | |
| **Correlation ID** | Identifies one end-to-end business interaction across all hops. | Not a trace ID (which is per-telemetry) |
| **Causation ID** | The ID of the message that directly caused this one. Parent pointer, forming a causal tree. | |
| **Dedup Key** | The value that makes reprocessing safe. Provider-supplied where possible. | |

## Workflows

| Term | Definition | Deliberately NOT |
|------|-----------|------------------|
| **Workflow Definition** | The authored template: a graph of steps. Mutable only by creating a new version. | Not the thing that "runs" |
| **Workflow Version** | An immutable, published snapshot of a definition. Runs pin to one. | |
| **Workflow Run** | One durable execution instance of a version. Has its own state, variables, and timeline. | Not "job", not "instance" |
| **Step** | A node in a definition. | |
| **Step Execution** | One *attempt* at a step within a run. Retries create new step executions, never mutate the old one. | |
| **Durable State** | Run state persisted such that it survives process death. | Never in-memory |
| **Compensation** | The action that semantically undoes a completed step when a later step fails. | Not a database rollback |
| **Approval Request** | A durable pause point requiring a human decision, with its full context captured. | |
| **Escalation** | Routing an unanswered or low-confidence decision to a higher authority after a deadline. | |
| **Lease** | A time-bounded claim by a worker on a run. Expiry allows another worker to take over safely. | Not a lock (locks don't expire on crash) |

## Agents & AI

| Term | Definition | Deliberately NOT |
|------|-----------|------------------|
| **Agent** | A configured, tenant-scoped AI principal with a purpose, tool set, permissions, memory, and budgets. | Not "the model" |
| **Agent Execution** | One bounded run of an agent: prompt(s), tool calls, decision, cost. Fully recorded. | |
| **Tool** | A registered, schema-validated capability an agent may invoke, subject to authorization. | Not "function calling" as a raw model feature |
| **Risk Tier** | `LOW` / `MEDIUM` / `HIGH` classification of a tool's blast radius. Drives approval policy. | |
| **Short-term memory** | Working context for the current execution only. Discarded after. | |
| **Episodic memory** | Records of past executions the agent may consult. | |
| **Semantic memory** | Durable, curated knowledge (facts, procedures) available across executions. | |
| **Confidence** | The agent's self-reported certainty, **treated as a routing hint, never as a guarantee**. | Not a probability we trust |
| **Grounding / Citation** | The link from a generated claim to the exact retrieved chunk supporting it. | |
| **Untrusted content** | Any text originating outside our system policy: documents, tool results, model output. Framed as data. | Never instructions (FR-404) |

## Money & governance

| Term | Definition |
|------|-----------|
| **Usage Record** | An immutable metered fact: what was consumed, by whom, for what, at what unit price. |
| **Budget** | A ceiling on spend for a scope (tenant / agent / workflow / user) over a period. |
| **Cost Attribution** | Assigning a usage record to every relevant dimension so any slice is answerable. |
| **Runaway** | An execution exceeding a ceiling (cost, time, steps, depth). Terminated by the platform, not by hope. |

## Audit

| Term | Definition |
|------|-----------|
| **Audit Record** | Immutable, hash-chained entry: who did what, to what, when, with what result. |
| **Timeline** | The ordered, human-readable reconstruction of a run or execution from its records. |
| **Tamper evidence** | The property that modifying history breaks a verifiable hash chain. |
