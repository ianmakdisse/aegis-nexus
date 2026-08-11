# frozen_string_literal: true

require "rails_helper"

# A projection over a real read model would couple these specs to whichever
# context owned it, and the contexts that own read models are Phases 7-10. The
# mechanics under test are checkpointing, ordering, skipping, rebuild and lag —
# all of which live in the base class. The subclass's own persistence is its
# business, and `reset!` is where the two meet.
class TallyProjection < Nexus::Projections::Projection
  projects "counter.incremented"

  def self.store = @store ||= Hash.new(0)
  def self.applied = @applied ||= []

  def project(envelope)
    self.class.store[Nexus::Tenancy::Context.organization_id] += envelope.payload["by"].to_i
    self.class.applied << envelope.event_id
  end

  def reset!
    self.class.store.delete(Nexus::Tenancy::Context.organization_id)
  end
end

RSpec.describe Nexus::Projections::Projection do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  before do
    register_event_type!(key: "counter.incremented", schema: { "by" => "integer" })
    register_event_type!(key: "counter.reset", schema: {})
    TallyProjection.instance_variable_set(:@store, nil)
    TallyProjection.instance_variable_set(:@applied, nil)
  end

  def emit!(by:, type: "counter.incremented")
    publish!(organization_id, envelope_for(key: type, payload: { "by" => by }, partition_key: "counter-1"))
    relay!(organization_id)
  end

  describe "projecting" do
    it "applies matching events to the read model" do
      emit!(by: 3)
      emit!(by: 4)

      TallyProjection.consume(organization_id: organization_id)

      expect(TallyProjection.store[organization_id]).to eq(7)
    end

    # Skipping is a decision, not a deferral: the cursor still advances, because
    # the projection has genuinely finished with that event.
    it "skips event types it does not project, without stalling" do
      emit!(by: 5)
      emit!(by: 0, type: "counter.reset")
      emit!(by: 2)

      TallyProjection.consume(organization_id: organization_id)

      expect(TallyProjection.store[organization_id]).to eq(7)
      expect(TallyProjection.applied.size).to eq(2)
    end

    it "checkpoints, so a second pass reapplies nothing" do
      emit!(by: 6)
      TallyProjection.consume(organization_id: organization_id)

      expect(TallyProjection.consume(organization_id: organization_id).processed).to eq(0)
      expect(TallyProjection.store[organization_id]).to eq(6)
    end

    it "applies an event once even when it is delivered twice" do
      emit!(by: 9)
      TallyProjection.consume(organization_id: organization_id)

      as_tenant(organization_id) { Nexus::Events::Internal::Models::EventLogCursor.update_all(position: 0) }
      TallyProjection.consume(organization_id: organization_id)

      expect(TallyProjection.store[organization_id]).to eq(9)
    end
  end

  describe "roles" do
    # An `api` pod must not run consumers and a projector must not run ordinary
    # handlers; a role that quietly runs someone else's work multiplies
    # concurrency on the next deploy that scales it.
    it "runs in the projector role, not the consumer role" do
      expect(TallyProjection.role).to eq(:projector)
      expect(Nexus::Events::Consumer.registry_for(:projector)).to include(TallyProjection)
      expect(Nexus::Events::Consumer.registry_for(:consumer)).not_to include(TallyProjection)
    end

    it "gets its own group, so adding a projection does not replay the others" do
      expect(TallyProjection.group_name).to eq("projection:tally_projection")
      expect(RecordingConsumer.group_name).not_to eq(TallyProjection.group_name)
    end
  end

  describe "rebuild — what makes derived data non-authoritative" do
    it "truncates, replays, and arrives at the same answer" do
      emit!(by: 2)
      emit!(by: 3)
      TallyProjection.consume(organization_id: organization_id)
      expect(TallyProjection.store[organization_id]).to eq(5)

      result = Nexus::Projections::Rebuild.call(projection: TallyProjection,
                                                organization_id: organization_id)

      expect(result.replayed).to eq(2)
      expect(TallyProjection.store[organization_id]).to eq(5)
    end

    # The failure this exists to prevent: rebuilding without truncating
    # double-counts, because the projection re-applies what it already applied.
    it "does not double-count" do
      emit!(by: 10)
      TallyProjection.consume(organization_id: organization_id)

      3.times { Nexus::Projections::Rebuild.call(projection: TallyProjection, organization_id: organization_id) }

      expect(TallyProjection.store[organization_id]).to eq(10)
    end

    it "recovers a read model that was corrupted out from under it" do
      emit!(by: 4)
      TallyProjection.consume(organization_id: organization_id)
      TallyProjection.store[organization_id] = 9_999   # something wrote nonsense

      Nexus::Projections::Rebuild.call(projection: TallyProjection, organization_id: organization_id)

      expect(TallyProjection.store[organization_id]).to eq(4)
    end

    it "refuses to rebuild something that is not a projection" do
      expect { Nexus::Projections::Rebuild.call(projection: RecordingConsumer, organization_id: organization_id) }
        .to raise_error(ArgumentError, /not a Nexus::Projections::Projection/)
    end

    it "rebuilds only the tenant it was asked about" do
      other = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")
      emit!(by: 7)
      TallyProjection.consume(organization_id: organization_id)
      TallyProjection.store[other] = 42

      Nexus::Projections::Rebuild.call(projection: TallyProjection, organization_id: organization_id)

      expect(TallyProjection.store[other]).to eq(42)
    end
  end

  describe "lag" do
    it "reports zero when caught up" do
      emit!(by: 1)
      TallyProjection.consume(organization_id: organization_id)

      lag = Nexus::Projections::Runner.lag(organization_id: organization_id)
                                      .find { |l| l.projection == "TallyProjection" }

      expect(lag).to be_caught_up
    end

    it "reports how far behind it is when events are waiting" do
      emit!(by: 1)
      emit!(by: 1)

      lag = Nexus::Projections::Runner.lag(organization_id: organization_id)
                                      .find { |l| l.projection == "TallyProjection" }

      expect(lag.behind).to eq(2)
      expect(lag).not_to be_caught_up
    end
  end

  describe "the runner" do
    it "drives every projection across every tenant in one tick" do
      emit!(by: 8)

      expect(Nexus::Projections::Runner.tick).to be >= 1
      expect(TallyProjection.store[organization_id]).to eq(8)
    end
  end
end
