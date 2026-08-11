# frozen_string_literal: true

require "rails_helper"

# ADR-006 — the durable workflow engine, and the highest-risk decision in the
# system. These specs cover the two properties the whole argument rests on:
# runs are pinned to a version, and workers hold leases that expire.
RSpec.describe "the workflow engine" do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  def definition(step_key: "notify")
    { "steps" => [{ "key" => step_key, "type" => "http" }] }
  end

  def in_tenant(&block) = as_tenant(organization_id) { block.call }

  def published!(key: "order_review", steps: definition)
    in_tenant do
      Nexus::Workflows::Definition.create!(key: key, name: key.humanize)
      Nexus::Workflows::Definition.publish!(key: key, definition: steps)
    end
  end

  describe "definitions are data, and publishing validates them" do
    it "publishes a version and activates the definition" do
      version = published!

      expect(version.version).to eq(1)
      expect(version).to be_published
      in_tenant { expect(Nexus::Workflows::Definition.find!("order_review").status).to eq("active") }
    end

    it "numbers versions sequentially" do
      published!
      second = in_tenant { Nexus::Workflows::Definition.publish!(key: "order_review", definition: definition) }

      expect(second.version).to eq(2)
    end

    it "rejects a definition with no steps" do
      in_tenant do
        Nexus::Workflows::Definition.create!(key: "empty", name: "Empty")

        expect { Nexus::Workflows::Definition.publish!(key: "empty", definition: { "steps" => [] }) }
          .to raise_error(Nexus::Workflows::Definition::InvalidDefinition, /at least one step/)
      end
    end

    it "rejects duplicate step keys" do
      in_tenant do
        Nexus::Workflows::Definition.create!(key: "dupe", name: "Dupe")
        steps = { "steps" => [{ "key" => "a", "type" => "http" }, { "key" => "a", "type" => "http" }] }

        expect { Nexus::Workflows::Definition.publish!(key: "dupe", definition: steps) }
          .to raise_error(Nexus::Workflows::Definition::InvalidDefinition, /duplicate step key/)
      end
    end

    it "refuses to run a definition that has never been published" do
      in_tenant do
        Nexus::Workflows::Definition.create!(key: "draft_only", name: "Draft")

        expect { Nexus::Workflows::Run.start!(definition_key: "draft_only") }
          .to raise_error(Nexus::Workflows::Definition::NotFound, /no published version/)
      end
    end
  end

  describe "INV-12 — a run is pinned to its definition version" do
    # The property the engine's safety rests on. Publishing a fix must not
    # reach a run already in flight: mutating a running program's instructions
    # is the most direct route to corrupt business state, and the damage is
    # silent because the evidence of what the program *was* has been overwritten.
    it "keeps executing the version it started with after a republish" do
      published!(steps: definition(step_key: "original"))

      run = in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review") }
      in_tenant do
        Nexus::Workflows::Definition.publish!(key: "order_review",
                                              definition: definition(step_key: "replaced"))
      end

      in_tenant do
        steps = Nexus::Workflows::Run.definition_for(run.id)["steps"]
        expect(steps.first["key"]).to eq("original")
      end
    end

    it "starts new runs on the newest published version" do
      published!(steps: definition(step_key: "original"))
      in_tenant do
        Nexus::Workflows::Definition.publish!(key: "order_review",
                                              definition: definition(step_key: "replaced"))
      end

      run = in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review") }

      in_tenant do
        expect(Nexus::Workflows::Run.definition_for(run.id)["steps"].first["key"]).to eq("replaced")
      end
    end

    # A version row mutated in place is the one thing INV-12 forbids that the
    # database cannot prevent on its own.
    it "refuses to execute a version whose definition was edited in place" do
      published!
      run = in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review") }

      in_tenant do
        Nexus::Workflows::Internal::Models::WorkflowVersion
          .find(run.workflow_version_id)
          .update_columns(definition: definition(step_key: "tampered"))

        expect { Nexus::Workflows::Run.definition_for(run.id) }
          .to raise_error(Nexus::Workflows::Run::Error, /failed its checksum/)
      end
    end
  end

  describe "starting runs" do
    it "is idempotent on the trigger key" do
      published!

      first = in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review", idempotency_key: "evt-1") }
      second = in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review", idempotency_key: "evt-1") }

      expect(second.id).to eq(first.id)
      in_tenant { expect(Nexus::Workflows::Internal::Models::WorkflowRun.count).to eq(1) }
    end

    it "carries a correlation id so the whole operation is one query" do
      published!
      run = in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review") }

      expect(run.correlation_id).to be_present
    end
  end

  describe "leases, not locks" do
    let(:run_id) { published! && in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review") }.id }
    let(:lease) { Nexus::Workflows::Internal::Engine::Lease }

    it "grants the run to one worker" do
      in_tenant do
        held = lease.acquire(run_id: run_id, worker_id: "worker-a")

        expect(held.worker_id).to eq("worker-a")
        expect(held.fence_token).to eq(1)
      end
    end

    it "refuses a second worker while the lease is live" do
      in_tenant do
        lease.acquire(run_id: run_id, worker_id: "worker-a")

        expect(lease.acquire(run_id: run_id, worker_id: "worker-b")).to be_nil
      end
    end

    # The reason this is a lease at all. A worker killed mid-step — which
    # happens on every deploy — never releases anything, so the run must become
    # reclaimable without human intervention.
    it "lets another worker reclaim it once it has expired" do
      in_tenant do
        lease.acquire(run_id: run_id, worker_id: "worker-a", duration: -1.second)

        reclaimed = lease.acquire(run_id: run_id, worker_id: "worker-b")

        expect(reclaimed.worker_id).to eq("worker-b")
        expect(reclaimed.fence_token).to eq(2)   # monotonic
      end
    end

    # The fence. A worker that was paused long enough to lose its lease wakes
    # up holding a stale token; its writes must be refused rather than silently
    # accepted, or two workers corrupt the run between them.
    it "refuses writes from a worker whose lease was taken" do
      in_tenant do
        stale = lease.acquire(run_id: run_id, worker_id: "worker-a", duration: -1.second)
        lease.acquire(run_id: run_id, worker_id: "worker-b")

        expect { lease.assert_held!(stale) }.to raise_error(lease::Lost, /no longer holds/)
        expect { lease.renew!(stale) }.to raise_error(lease::Lost)
      end
    end

    it "lets the holder renew while it is genuinely working" do
      in_tenant do
        held = lease.acquire(run_id: run_id, worker_id: "worker-a")

        expect { lease.renew!(held) }.not_to raise_error
        expect(lease.assert_held!(held)).to be(true)
      end
    end

    it "frees the run when the holder releases it" do
      in_tenant do
        held = lease.acquire(run_id: run_id, worker_id: "worker-a")
        lease.release!(held)

        expect(lease.acquire(run_id: run_id, worker_id: "worker-b")).not_to be_nil
      end
    end

    # Expiry is the database's judgement, never the worker's. A worker with a
    # fast clock must not be able to honour a lease PostgreSQL considers dead.
    it "decides expiry with the database clock, not the worker's" do
      in_tenant do
        lease.acquire(run_id: run_id, worker_id: "worker-a", duration: 60.seconds)

        expect(lease.held_by(run_id: run_id)).to eq("worker-a")

        Nexus::Workflows::Internal::Models::RunLease
          .where(workflow_run_id: run_id)
          .update_all(expires_at: Arel.sql("now() - interval '1 second'"))

        expect(lease.held_by(run_id: run_id)).to be_nil
      end
    end
  end

  describe "step attempts are immutable" do
    it "records each attempt as a new row rather than overwriting the last" do
      published!
      run = in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review") }
      model = Nexus::Workflows::Internal::Models::StepExecution

      in_tenant do
        2.times do |i|
          model.create!(
            workflow_run_id: run.id, step_key: "notify", step_type: "http", attempt: i + 1,
            status: i.zero? ? "failed" : "succeeded", started_at: Time.current,
            idempotency_key: model.idempotency_key_for(run_id: run.id, step_key: "notify", attempt: i + 1)
          )
        end

        attempts = model.where(workflow_run_id: run.id).order(:attempt)
        expect(attempts.map(&:status)).to eq(%w[failed succeeded])
      end
    end

    it "derives the idempotency key from durable identifiers only" do
      model = Nexus::Workflows::Internal::Models::StepExecution
      key = model.idempotency_key_for(run_id: "r1", step_key: "notify", attempt: 2)

      expect(key).to eq("run:r1:step:notify:attempt:2")
      expect(model.idempotency_key_for(run_id: "r1", step_key: "notify", attempt: 2)).to eq(key)
    end
  end

  describe "tenant isolation" do
    it "does not expose one tenant's run to another" do
      other = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")
      published!
      run = in_tenant { Nexus::Workflows::Run.start!(definition_key: "order_review") }

      as_tenant(other) do
        expect { Nexus::Workflows::Run.find!(run.id) }.to raise_error(Nexus::Workflows::Run::NotFound)
      end
    end
  end
end
