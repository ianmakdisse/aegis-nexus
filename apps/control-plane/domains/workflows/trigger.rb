# frozen_string_literal: true

module Nexus
  module Workflows
    # Public contract: start a workflow run from an event or an API call.
    class Trigger
      def call(definition_key:, payload:, principal:)
        # The definition key is an *attribute* of the request, not the resource
        # type: the permission is `workflows.trigger`, and which definition it is
        # allowed to start is a policy question a tenant may narrow.
        Nexus::Authorization::Authorize.call!(
          principal, :trigger, :workflows,
          attributes: { "definition_key" => definition_key }
        )

        Internal::Engine::Starter.new.start(definition_key, payload)
      end
    end
  end
end
