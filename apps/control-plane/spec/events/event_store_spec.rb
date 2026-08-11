# frozen_string_literal: true

require "rails_helper"

# ADR-005 — event sourcing for exactly four aggregates. These specs exercise the
# machinery those four will use; the aggregates themselves are Phases 7 and 8.
class Counter < Nexus::EventStore::Aggregate
  stream_type "Counter"

  on("counter.incremented") { |state, payload| state.merge("total" => state.fetch("total", 0) + payload["by"]) }
  on("counter.reset") { |state, _payload| state.merge("total" => 0) }

  def increment(by) = emit("counter.incremented", "by" => by)
  def reset = emit("counter.reset")
  def total = state.fetch("total", 0)
end

RSpec.describe Nexus::Events::EventStore do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  before do
    register_event_type!(key: "counter.incremented", schema: { "by" => "integer" })
    register_event_type!(key: "counter.reset", schema: {})
  end

  def counter(&block) = as_tenant(organization_id) { block.call }

  describe "append and load" do
    it "records history and folds it back into state" do
      id = SecureRandom.uuid

      counter do
        c = Counter.new_stream(id)
        c.increment(3).increment(4)
        c.save!
        expect(c.total).to eq(7)
        expect(c.sequence).to eq(2)
      end

      counter { expect(Counter.load(id).total).to eq(7) }
    end

    it "returns an empty aggregate for a stream that does not exist" do
      counter do
        loaded = described_class.load(stream_id: SecureRandom.uuid, stream_type: "Counter")

        expect(loaded).to be_empty
        expect(loaded.events).to be_empty
      end
    end

    it "keeps events in sequence order" do
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(1).increment(2).reset.save! }

      counter do
        loaded = described_class.load(stream_id: id, stream_type: "Counter")

        expect(loaded.events.map(&:event_type))
          .to eq(%w[counter.incremented counter.incremented counter.reset])
        expect(loaded.sequence).to eq(3)
      end
    end
  end

  describe "optimistic concurrency" do
    # A SELECT max(sequence) followed by an INSERT is a race that two concurrent
    # workers both win. The unique index is the actual check.
    it "refuses a write from a stale aggregate" do
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(1).save! }

      counter do
        stale = Counter.load(id)     # sequence 1
        Counter.load(id).increment(5).save!  # someone else advances to 2

        expect { stale.increment(1).save! }
          .to raise_error(described_class::ConcurrencyConflict, /advanced past sequence 1/)
      end
    end

    it "leaves the winner's history intact after a conflict" do
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(1).save! }

      counter do
        stale = Counter.load(id)
        Counter.load(id).increment(5).save!
        begin
          stale.increment(99).save!
        rescue described_class::ConcurrencyConflict
          nil
        end

        expect(Counter.load(id).total).to eq(6)
      end
    end
  end

  describe "publication" do
    # The event row and its outbox row commit together (INV-04). An aggregate
    # whose history advanced but whose events never reached the backbone is the
    # dual-write bug wearing a different hat.
    it "writes an outbox row in the same transaction as the event" do
      id = SecureRandom.uuid

      expect {
        counter { Counter.new_stream(id).increment(1).save! }
      }.to change {
        as_tenant(organization_id) { Nexus::Events::Internal::Models::OutboxMessage.count }
      }.by(1)
    end

    # The stream id is the partition key, so every event for one aggregate is
    # delivered in order (INV-09). Anything else silently breaks per-aggregate
    # ordering downstream.
    it "partitions published events by stream id" do
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(1).save! }

      row = as_tenant(organization_id) { Nexus::Events::Internal::Models::OutboxMessage.last }
      expect(row.partition_key).to eq(id)
    end
  end

  describe "snapshots" do
    it "is a cache: deleting every snapshot changes no answer" do
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(2).increment(3).save! }
      counter { described_class.snapshot!(stream_id: id, stream_type: "Counter", sequence: 2, state: { "total" => 5 }) }

      counter do
        expect(Counter.load(id).total).to eq(5)
        Nexus::Events::Internal::Models::EventStoreSnapshot.delete_all
        expect(Counter.load(id).total).to eq(5)   # full replay, same answer
      end
    end

    it "folds only the events after the snapshot" do
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(2).save! }
      counter { described_class.snapshot!(stream_id: id, stream_type: "Counter", sequence: 1, state: { "total" => 2 }) }
      counter { Counter.load(id).increment(10).save! }

      counter do
        loaded = described_class.load(stream_id: id, stream_type: "Counter")

        expect(loaded.snapshot).to eq("total" => 2)
        expect(loaded.events.size).to eq(1)          # not two
        expect(Counter.load(id).total).to eq(12)
      end
    end

    it "takes one every SNAPSHOT_INTERVAL events" do
      expect(described_class.snapshot_due?(described_class::SNAPSHOT_INTERVAL)).to be(true)
      expect(described_class.snapshot_due?(1)).to be(false)
      expect(described_class.snapshot_due?(0)).to be(false)
    end
  end

  describe "replay determinism" do
    # If the fold is not deterministic, history stops determining state and the
    # event log becomes decoration. This is the property every applier's purity
    # rule exists to protect.
    it "produces the same state every time it is rebuilt" do
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(1).increment(2).reset.increment(9).save! }

      results = counter { 3.times.map { Counter.load(id).total } }

      expect(results).to eq([9, 9, 9])
    end

    # An older deployment must not crash on an event a newer one emitted.
    it "ignores event types it does not understand rather than failing the fold" do
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(4).save! }
      register_event_type!(key: "counter.teleported", schema: {})

      counter do
        described_class.append(
          stream_id: id, stream_type: "Counter", expected_sequence: 1,
          events: [Nexus::Events::Envelope.new(event_type: "counter.teleported", payload: {},
                                               partition_key: id, organization_id: organization_id)]
        )

        expect(Counter.load(id).total).to eq(4)
        expect(Counter.load(id).sequence).to eq(2)
      end
    end
  end

  describe "tenant isolation" do
    it "does not expose one tenant's stream to another" do
      other = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")
      id = SecureRandom.uuid
      counter { Counter.new_stream(id).increment(1).save! }

      as_tenant(other) do
        expect(described_class.load(stream_id: id, stream_type: "Counter")).to be_empty
      end
    end
  end
end
