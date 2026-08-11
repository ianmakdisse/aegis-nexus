# frozen_string_literal: true

module EventsHelpers
  TOPIC = Nexus::Events::Relay::DEFAULT_TOPIC

  # Handlers record what they saw in a process-local sink rather than a
  # database table, so a test can distinguish "the handler ran twice" from
  # "the handler's writes committed twice" — which are different bugs.
  def self.sink = @sink ||= Hash.new { |h, k| h[k] = [] }
  def self.reset! = @sink = nil

  def sink = EventsHelpers.sink

  def register_event_type!(key: "test.thing.happened", version: 1, schema: { "id" => "string" })
    Nexus::Events::EventType.register!(
      key: key, version: version, schema: schema, owning_context: "events"
    )
  end

  def envelope_for(key: "test.thing.happened", payload: { "id" => "1" }, partition_key: "aggregate-1", **rest)
    Nexus::Events::Envelope.new(
      event_type: key, payload: payload, partition_key: partition_key, **rest
    )
  end

  # Publish inside a tenant, the way a domain command would: one transaction
  # holding both the (notional) state change and the outbox row.
  def publish!(organization_id, envelope = nil)
    envelope ||= envelope_for
    as_tenant(organization_id) { Nexus::Events::Publisher.publish(envelope) }
  end

  def relay!(organization_id) = Nexus::Events::Relay.drain(organization_id: organization_id)

  def log_entries(organization_id)
    as_tenant(organization_id) { Nexus::Events::Internal::Models::EventLogEntry.order(:position).to_a }
  end

  def inbox_rows(organization_id, group)
    as_tenant(organization_id) do
      Nexus::Events::Internal::Models::InboxMessage.where(consumer_group: group).to_a
    end
  end

  def dead_letters(organization_id, group)
    as_tenant(organization_id) do
      Nexus::Events::Internal::Models::DeadLetterMessage.where(consumer_group: group).to_a
    end
  end
end

# A handler that records every delivery. Defined once at load time because
# subclassing Consumer registers it, and re-registering per example would grow
# the registry without bound.
class RecordingConsumer < Nexus::Events::Consumer
  consumes topic: EventsHelpers::TOPIC, group: "recorder"

  def dedup_key(envelope) = envelope.event_id
  def handle(envelope) = EventsHelpers.sink[:recorded] << envelope.payload["id"]
end

# A handler that always fails, to exercise the retry and dead-letter path.
class FailingConsumer < Nexus::Events::Consumer
  consumes topic: EventsHelpers::TOPIC, group: "failer"

  def dedup_key(envelope) = envelope.event_id

  def handle(envelope)
    EventsHelpers.sink[:attempted] << envelope.event_id
    raise "handler is broken on purpose"
  end
end

# A handler that forgets its dedup key — the mistake INV-05's enforcement
# exists to make impossible to ship.
class KeylessConsumer < Nexus::Events::Consumer
  consumes topic: EventsHelpers::TOPIC, group: "keyless"

  def handle(_envelope) = EventsHelpers.sink[:keyless] << :ran
end

RSpec.configure do |config|
  config.include EventsHelpers
  config.before { EventsHelpers.reset! }
end
