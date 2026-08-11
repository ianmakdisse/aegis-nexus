# frozen_string_literal: true

module Nexus
  module Events
    # Published contract: the event vocabulary, and the rule that keeps it
    # evolvable (INV-10).
    #
    # WHY ADDITIVE-ONLY IS NOT NEGOTIABLE
    #
    # The event log is permanent. A stored event from six months ago will be
    # replayed by a projection rebuild, read by an auditor, and folded by an
    # aggregate — all using today's code. Removing a field, renaming it, or
    # changing its type does not change future messages; it changes *history*,
    # and every one of those readers breaks on data they cannot re-request.
    #
    # So within a major version: fields may be added. Nothing else. A breaking
    # change mints a new version, and the old version keeps being handled until
    # no stored event uses it — which is a query, not a guess.
    module EventType
      IncompatibleChange = Class.new(StandardError)
      Unknown = Class.new(StandardError)

      module_function

      # Register a type, or verify that a re-registration is additive.
      #
      # Runs with no tenant context: the registry is platform-global vocabulary,
      # for the same reason `permissions` is (ADR-012).
      def register!(key:, version: 1, schema: {}, owning_context:, status: "active")
        Tenancy::Context.without_tenant_for_platform_operation do
          existing = Internal::Models::EventTypeRecord.find_by(key: key, version: version)
          return create!(key, version, schema, owning_context, status) if existing.nil?

          assert_additive!(existing.schema, schema, key, version)
          existing.update!(schema: schema, owning_context: owning_context, status: status)
          existing
        end
      end

      def known?(key, version = 1)
        Tenancy::Context.without_tenant_for_platform_operation do
          Internal::Models::EventTypeRecord.exists?(key: key, version: version)
        end
      end

      # Versions of a key that are still handled, newest first.
      def versions(key)
        Tenancy::Context.without_tenant_for_platform_operation do
          Internal::Models::EventTypeRecord.where(key: key).order(version: :desc).pluck(:version)
        end
      end

      def latest_version(key) = versions(key).first

      # The check a publisher makes. Publishing an unregistered type is refused
      # rather than logged: an event nobody declared is one no consumer can be
      # expected to handle, and it is permanent once written.
      def assert_registered!(key, version)
        return if known?(key, version)

        raise Unknown,
              "event type `#{key}` v#{version} is not registered. Declare it with " \
              "Nexus::Events::EventType.register! before publishing — the log is permanent, " \
              "so an undeclared type is an undeclared permanent commitment."
      end

      # @raise [IncompatibleChange] if the new schema removes or retypes a field
      def assert_additive!(old_schema, new_schema, key, version)
        old_fields = field_types(old_schema)
        new_fields = field_types(new_schema)

        removed = old_fields.keys - new_fields.keys
        retyped = (old_fields.keys & new_fields.keys).reject { |f| old_fields[f] == new_fields[f] }
        return if removed.empty? && retyped.empty?

        raise IncompatibleChange,
              "`#{key}` v#{version} would change history: " \
              "#{"removed #{removed.join(', ')}" if removed.any?}" \
              "#{'; ' if removed.any? && retyped.any?}" \
              "#{"retyped #{retyped.join(', ')}" if retyped.any?}. " \
              "Within a major version fields may only be ADDED (INV-10). " \
              "Register v#{version + 1} instead and keep v#{version} until no stored event uses it."
      end

      def create!(key, version, schema, owning_context, status)
        Internal::Models::EventTypeRecord.create!(
          key: key, version: version, schema: schema,
          owning_context: owning_context, status: status
        )
      end

      # Reads a JSON-Schema-ish `{"properties" => {"name" => {"type" => "string"}}}`
      # shape, and tolerates a flat `{"name" => "string"}` one. Only field names
      # and types matter to compatibility; everything else is documentation.
      def field_types(schema)
        schema = (schema || {}).transform_keys(&:to_s)
        properties = schema["properties"] || schema

        (properties || {}).to_h do |name, spec|
          type = spec.is_a?(Hash) ? (spec["type"] || spec[:type]) : spec
          [name.to_s, type.to_s]
        end
      end
    end
  end
end
