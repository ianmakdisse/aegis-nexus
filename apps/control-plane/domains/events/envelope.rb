# frozen_string_literal: true

module Nexus
  module Events
    # Published contract: the shape of every event in the system.
    #
    # An envelope is immutable and self-describing. Three fields do work that is
    # easy to underestimate:
    #
    #   `version`        INV-10. The log is permanent, so a schema change is a
    #                    change to *history*, not just to future messages.
    #   `partition_key`  INV-09. Ordering is guaranteed only among events sharing
    #                    a key. Choosing the key IS choosing what is ordered.
    #   `correlation_id` INV-23. The whole story of an operation is one query on
    #                    this, across HTTP, the outbox, the backbone and workers.
    #
    # `causation_id` is the id of the event that directly caused this one, where
    # `correlation_id` is the id of the operation the whole chain belongs to.
    # Conflating them loses the ability to reconstruct a tree from a list.
    class Envelope
      Invalid = Class.new(StandardError)

      attr_reader :event_type, :version, :payload, :partition_key, :organization_id,
                  :event_id, :occurred_at, :trace_id, :correlation_id, :causation_id, :actor

      def initialize(event_type:, payload:, partition_key:, organization_id: nil, version: 1,
                     event_id: nil, occurred_at: nil, trace_id: nil, correlation_id: nil,
                     causation_id: nil, actor: nil)
        @event_type = event_type.to_s
        @version = Integer(version)
        @payload = deep_stringify(payload || {})
        @partition_key = partition_key.to_s
        @organization_id = organization_id
        @event_id = event_id || SecureRandom.uuid
        @occurred_at = occurred_at || Time.current
        @trace_id = trace_id
        # An event with no correlation is an event that cannot be traced back to
        # why it happened, so one is minted rather than left nil (INV-23).
        @correlation_id = correlation_id || @event_id
        @causation_id = causation_id
        @actor = actor
        validate!
        freeze
      end

      # Everything except the payload. This is what goes in `headers` on the wire
      # and in `metadata` in the outbox — deliberately separate from the payload,
      # so a consumer can route and trace without parsing domain data.
      def headers
        {
          "event_id" => event_id,
          "event_type" => event_type,
          "version" => version,
          "organization_id" => organization_id,
          "occurred_at" => occurred_at.iso8601(6),
          "trace_id" => trace_id,
          "correlation_id" => correlation_id,
          "causation_id" => causation_id,
          "actor" => actor
        }.compact
      end

      def self.from_headers(headers, payload)
        h = headers.transform_keys(&:to_s)
        new(
          event_type: h.fetch("event_type"), version: h.fetch("version", 1),
          payload: payload, partition_key: h["partition_key"].to_s,
          organization_id: h["organization_id"], event_id: h["event_id"],
          occurred_at: h["occurred_at"] && Time.parse(h["occurred_at"]),
          trace_id: h["trace_id"], correlation_id: h["correlation_id"],
          causation_id: h["causation_id"], actor: h["actor"]
        )
      end

      # An event caused by this one, inheriting the correlation and pointing back
      # through causation. Written as a method so the chain cannot be broken by
      # someone forgetting to copy two fields.
      def caused(event_type:, payload:, partition_key: nil, version: 1)
        self.class.new(
          event_type: event_type, payload: payload, version: version,
          partition_key: partition_key || self.partition_key,
          organization_id: organization_id, trace_id: trace_id,
          correlation_id: correlation_id, causation_id: event_id, actor: actor
        )
      end

      def to_h = headers.merge("payload" => payload, "partition_key" => partition_key)

      private

      def validate!
        raise Invalid, "event_type is required" if event_type.empty?
        raise Invalid, "version must be positive" unless version.positive?
        # A blank partition key would make ordering arbitrary while looking
        # fine — the failure would surface much later as events processed out of
        # order for one aggregate, which is close to undebuggable.
        raise Invalid, "partition_key is required (INV-09: ordering is per-key)" if partition_key.empty?
      end

      def deep_stringify(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s, deep_stringify(v)] }
        when Array then value.map { |v| deep_stringify(v) }
        else value
        end
      end
    end
  end
end
