# frozen_string_literal: true

module Nexus
  module Workflows
    # Public contract: start a workflow run from an event or an API call.
    class Trigger
      # `idempotency_key` is optional but should almost never be omitted:
      # delivery is at-least-once, so a trigger without one starts a second run
      # on the next relay restart.
      def call(definition_key:, payload:, principal:, idempotency_key: nil,
               correlation_id: nil, source: "api")
        # The definition key is an *attribute* of the request, not the resource
        # type: the permission is `workflows.trigger`, and which definition it is
        # allowed to start is a policy question a tenant may narrow.
        Nexus::Authorization::Authorize.call!(
          principal, :trigger, :workflows,
          attributes: { "definition_key" => definition_key }
        )

        Run.start!(
          definition_key: definition_key,
          input: payload,
          idempotency_key: idempotency_key,
          correlation_id: correlation_id,
          trigger_source: source
        )
      end
    end
  end
end
