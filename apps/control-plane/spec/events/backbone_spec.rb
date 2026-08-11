# frozen_string_literal: true

require "rails_helper"

# The correctness tests ADR-003 exists to make runnable: duplicate delivery,
# replay, and crash recovery, exercised against a single PostgreSQL instance
# with no broker. That was the whole argument for the transport port.
RSpec.describe "the event backbone" do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  before { register_event_type! }

  describe "outbox → log" do
    it "publishes committed outbox rows and marks them" do
      publish!(organization_id, envelope_for(payload: { "id" => "1" }))

      expect(relay!(organization_id)).to eq(1)

      entries = log_entries(organization_id)
      expect(entries.size).to eq(1)
      expect(entries.first.payload).to eq("id" => "1")
      expect(as_tenant(organization_id) do
        Nexus::Events::Internal::Models::OutboxMessage.last.published_at
      end).to be_present
    end

    it "does not republish a message it already published" do
      publish!(organization_id)
      relay!(organization_id)

      expect(relay!(organization_id)).to eq(0)
      expect(log_entries(organization_id).size).to eq(1)
    end

    it "keeps events sharing a partition key in the order they were committed" do
      3.times { |i| publish!(organization_id, envelope_for(payload: { "id" => i.to_s }, partition_key: "same")) }
      relay!(organization_id)

      entries = log_entries(organization_id)
      expect(entries.map { |e| e.payload["id"] }).to eq(%w[0 1 2])
      expect(entries.map(&:partition_number).uniq.size).to eq(1)
    end

    # CRASH RECOVERY. The relay publishes, then marks. A crash between the two
    # is the normal case, not an edge case — and the recovery must not produce
    # a second copy in the log.
    it "absorbs a republish after crashing between publish and mark" do
      publish!(organization_id)

      allow_any_instance_of(Nexus::Events::Internal::Models::OutboxMessage)
        .to receive(:update!).and_raise(StandardError, "killed after publish")
      expect { relay!(organization_id) }.to raise_error(StandardError, /killed after publish/)

      # The row is still unpublished, so the restarted relay tries again.
      RSpec::Mocks.space.proxy_for(Nexus::Events::Internal::Models::OutboxMessage).reset
      allow_any_instance_of(Nexus::Events::Internal::Models::OutboxMessage).to receive(:update!).and_call_original

      relay!(organization_id)

      expect(log_entries(organization_id).size).to eq(1)
    end
  end

  describe "log → handler" do
    it "delivers to the handler and records the claim" do
      publish!(organization_id, envelope_for(payload: { "id" => "7" }))
      relay!(organization_id)

      result = RecordingConsumer.consume(organization_id: organization_id)

      expect(result.processed).to eq(1)
      expect(sink[:recorded]).to eq(["7"])
      expect(inbox_rows(organization_id, "recorder").size).to eq(1)
    end

    it "advances the cursor so a second run delivers nothing" do
      publish!(organization_id)
      relay!(organization_id)
      RecordingConsumer.consume(organization_id: organization_id)

      expect(RecordingConsumer.consume(organization_id: organization_id).processed).to eq(0)
      expect(sink[:recorded].size).to eq(1)
    end

    # DUPLICATE DELIVERY. At-least-once is the substrate (INV-06), so the
    # handler must run once even when the event is delivered twice.
    it "runs the handler once when the same event is delivered twice" do
      publish!(organization_id)
      relay!(organization_id)

      RecordingConsumer.consume(organization_id: organization_id)
      # Rewind the cursor: the transport redelivers, exactly as a rebalance or
      # a crashed consumer would.
      as_tenant(organization_id) do
        Nexus::Events::Internal::Models::EventLogCursor.update_all(position: 0)
      end
      result = RecordingConsumer.consume(organization_id: organization_id)

      expect(result.duplicates).to eq(1)
      expect(result.processed).to eq(0)
      expect(sink[:recorded].size).to eq(1)
    end
  end

  describe "failure handling" do
    # THE LOAD-BEARING ONE. If the claim survived a failed handler, every retry
    # would be deduplicated away and the message silently dropped — worse than
    # the duplicate the inbox exists to prevent.
    it "rolls the inbox claim back when the handler fails, so the message stays retryable" do
      publish!(organization_id)
      relay!(organization_id)

      FailingConsumer.consume(organization_id: organization_id)

      expect(inbox_rows(organization_id, "failer")).to be_empty
    end

    it "retries in process before giving up" do
      publish!(organization_id)
      relay!(organization_id)

      FailingConsumer.consume(organization_id: organization_id)

      expect(sink[:attempted].size).to eq(Nexus::Events::Consumer::MAX_ATTEMPTS)
    end

    it "dead-letters the message with its payload and error" do
      publish!(organization_id, envelope_for(payload: { "id" => "9" }))
      relay!(organization_id)

      result = FailingConsumer.consume(organization_id: organization_id)

      expect(result.dead_lettered).to eq(1)
      letter = dead_letters(organization_id, "failer").first
      expect(letter.payload).to eq("id" => "9")
      expect(letter.error_message).to match(/broken on purpose/)
    end

    # A poison message that blocks its partition forever turns one bad event
    # into a tenant-wide outage.
    it "advances past a dead letter rather than blocking the partition" do
      publish!(organization_id)
      relay!(organization_id)
      FailingConsumer.consume(organization_id: organization_id)

      publish!(organization_id, envelope_for(payload: { "id" => "next" }))
      relay!(organization_id)

      expect(FailingConsumer.consume(organization_id: organization_id).dead_lettered).to eq(1)
      expect(dead_letters(organization_id, "failer").size).to eq(2)
    end

    # INV-05's enforcement: the base consumer refuses to run a handler that
    # cannot say what makes a delivery a duplicate.
    it "refuses to run a handler with no dedup key" do
      publish!(organization_id)
      relay!(organization_id)

      expect { KeylessConsumer.consume(organization_id: organization_id) }
        .to raise_error(Nexus::Events::Consumer::MissingDedupKey, /at-least-once/)
      expect(sink[:keyless]).to be_empty
    end
  end

  describe "replay (FR-208)" do
    it "delivers history to a new consumer group" do
      2.times { |i| publish!(organization_id, envelope_for(payload: { "id" => i.to_s })) }
      relay!(organization_id)
      RecordingConsumer.consume(organization_id: organization_id)
      expect(sink[:recorded].size).to eq(2)

      # A fresh group has no inbox claims, so history is genuinely re-delivered.
      stub_const("ReplayConsumer", Class.new(RecordingConsumer) do
        consumes topic: EventsHelpers::TOPIC, group: "replayed"
      end)
      Nexus::Events::Replay.into_group(target_group: "replayed", organization_id: organization_id)

      expect(ReplayConsumer.consume(organization_id: organization_id).processed).to eq(2)
      expect(sink[:recorded].size).to eq(4)
    end

    # Rewinding a cursor without purging claims looks like success and changes
    # nothing — the worst outcome for something reached for during an incident.
    it "refuses to reprocess a group without an explicit acknowledgement" do
      expect { Nexus::Events::Replay.reprocess!(group: "recorder", organization_id: organization_id) }
        .to raise_error(Nexus::Events::Replay::Refused, /already processed/)
    end

    it "reprocesses the same group when the caller accepts that handlers rerun" do
      publish!(organization_id)
      relay!(organization_id)
      RecordingConsumer.consume(organization_id: organization_id)

      Nexus::Events::Replay.reprocess!(group: "recorder", organization_id: organization_id,
                                       i_understand_handlers_will_rerun: true)

      expect(RecordingConsumer.consume(organization_id: organization_id).processed).to eq(1)
      expect(sink[:recorded].size).to eq(2)
    end
  end

  describe "tenant isolation" do
    it "never delivers one tenant's events to another" do
      other = provision_organization!(name: "Other", slug: "other-#{SecureRandom.hex(4)}")
      publish!(organization_id, envelope_for(payload: { "id" => "private" }))
      relay!(organization_id)

      expect(relay!(other)).to eq(0)
      expect(log_entries(other)).to be_empty
      expect(RecordingConsumer.consume(organization_id: other).processed).to eq(0)
      expect(sink[:recorded]).to be_empty
    end
  end
end
