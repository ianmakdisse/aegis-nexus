# frozen_string_literal: true

require "rails_helper"

# INV-04 — no dual writes. The guard is the entire reason this class exists.
RSpec.describe Nexus::Events::Publisher do
  let(:organization_id) { provision_organization!(name: "Acme", slug: "acme-#{SecureRandom.hex(4)}") }

  before { register_event_type! }

  describe "the transaction guard" do
    # The bug this makes unwritable: state committed, event not published,
    # crash in between. Nothing raises and the two halves disagree forever.
    it "refuses to publish outside a transaction" do
      allow(ActiveRecord::Base.connection).to receive(:transaction_open?).and_return(false)

      expect { publish!(organization_id) }
        .to raise_error(described_class::NotInTransaction, /INV-04/)
    end

    it "writes nothing when it refuses" do
      allow(ActiveRecord::Base.connection).to receive(:transaction_open?).and_return(false)

      expect { publish!(organization_id) rescue nil }
        .not_to change { as_tenant(organization_id) { Nexus::Events::Internal::Models::OutboxMessage.count } }
    end

    it "publishes inside one" do
      expect { publish!(organization_id) }
        .to change { as_tenant(organization_id) { Nexus::Events::Internal::Models::OutboxMessage.count } }.by(1)
    end
  end

  describe "what lands in the outbox" do
    it "carries the envelope's routing and trace context, separate from the payload" do
      envelope = envelope_for(payload: { "id" => "42" }, partition_key: "order-42",
                              trace_id: "trace-1", correlation_id: "corr-1")
      publish!(organization_id, envelope)

      row = as_tenant(organization_id) { Nexus::Events::Internal::Models::OutboxMessage.last }

      expect(row.partition_key).to eq("order-42")
      expect(row.payload).to eq("id" => "42")
      expect(row.metadata["trace_id"]).to eq("trace-1")
      expect(row.metadata["correlation_id"]).to eq("corr-1")
      expect(row.published_at).to be_nil
    end

    it "attributes the row to the tenant" do
      publish!(organization_id)
      row = as_tenant(organization_id) { Nexus::Events::Internal::Models::OutboxMessage.last }

      expect(row.organization_id).to eq(organization_id)
    end
  end

  describe "refusing undeclared events" do
    # The log is permanent, so an undeclared type is an undeclared permanent
    # commitment. Better to fail at the publish than to discover in six months
    # that nothing can handle it.
    it "refuses an unregistered event type" do
      envelope = envelope_for(key: "test.never.declared")

      expect { publish!(organization_id, envelope) }
        .to raise_error(Nexus::Events::EventType::Unknown, /not registered/)
    end

    it "refuses an unregistered version of a known type" do
      envelope = envelope_for(version: 7)

      expect { publish!(organization_id, envelope) }.to raise_error(Nexus::Events::EventType::Unknown)
    end
  end

  describe "tenancy" do
    it "refuses to publish with no tenant at all" do
      expect { ActiveRecord::Base.transaction { described_class.publish(envelope_for) } }
        .to raise_error(Nexus::Tenancy::Context::Missing)
    end
  end
end

RSpec.describe Nexus::Events::Envelope do
  it "requires a partition key, because ordering is per-key" do
    expect { described_class.new(event_type: "a.b", payload: {}, partition_key: "") }
      .to raise_error(described_class::Invalid, /INV-09/)
  end

  # An event with no correlation cannot be traced back to why it happened.
  it "mints a correlation id when none is given" do
    envelope = described_class.new(event_type: "a.b", payload: {}, partition_key: "k")

    expect(envelope.correlation_id).to eq(envelope.event_id)
  end

  it "keeps the correlation and points causation at its parent" do
    parent = described_class.new(event_type: "a.b", payload: {}, partition_key: "k",
                                 correlation_id: "corr-1")
    child = parent.caused(event_type: "a.c", payload: {})

    expect(child.correlation_id).to eq("corr-1")
    expect(child.causation_id).to eq(parent.event_id)
    expect(child.event_id).not_to eq(parent.event_id)
  end

  it "survives a round trip through headers" do
    original = described_class.new(event_type: "a.b", payload: { "n" => 1 }, partition_key: "k",
                                   trace_id: "t", organization_id: SecureRandom.uuid)
    restored = described_class.from_headers(
      original.headers.merge("partition_key" => original.partition_key), original.payload
    )

    expect(restored.event_id).to eq(original.event_id)
    expect(restored.trace_id).to eq("t")
    expect(restored.payload).to eq("n" => 1)
  end

  it "is immutable" do
    expect(described_class.new(event_type: "a.b", payload: {}, partition_key: "k")).to be_frozen
  end
end

# INV-10 — the log is permanent, so a schema change is a change to history.
RSpec.describe Nexus::Events::EventType do
  let(:key) { "test.evolving.#{SecureRandom.hex(3)}" }

  it "allows adding a field within a version" do
    described_class.register!(key: key, schema: { "a" => "string" }, owning_context: "events")

    expect {
      described_class.register!(key: key, schema: { "a" => "string", "b" => "integer" },
                                owning_context: "events")
    }.not_to raise_error
  end

  it "refuses to remove a field" do
    described_class.register!(key: key, schema: { "a" => "string", "b" => "integer" },
                              owning_context: "events")

    expect { described_class.register!(key: key, schema: { "a" => "string" }, owning_context: "events") }
      .to raise_error(described_class::IncompatibleChange, /removed b/)
  end

  it "refuses to change a field's type" do
    described_class.register!(key: key, schema: { "a" => "string" }, owning_context: "events")

    expect { described_class.register!(key: key, schema: { "a" => "integer" }, owning_context: "events") }
      .to raise_error(described_class::IncompatibleChange, /retyped a/)
  end

  it "allows a breaking change as a new version, keeping the old one" do
    described_class.register!(key: key, schema: { "a" => "string" }, owning_context: "events")
    described_class.register!(key: key, version: 2, schema: { "a" => "integer" }, owning_context: "events")

    expect(described_class.versions(key)).to eq([2, 1])
  end
end
