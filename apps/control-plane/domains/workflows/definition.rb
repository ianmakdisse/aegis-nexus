# frozen_string_literal: true

module Nexus
  module Workflows
    # Published contract: author and publish workflow definitions.
    #
    # A definition is tenant-authored **data**. That is ADR-006's central claim
    # and the reason the engine is built rather than adopted: a deployed-code
    # engine cannot let a tenant change a workflow without a deploy, and cannot
    # enforce platform governance on what they wrote.
    #
    # PUBLISHING CREATES AN IMMUTABLE VERSION, AND RUNS POINT AT THE VERSION
    #
    # Editing a definition does not touch any run. A run is pinned to the
    # version that existed when it started ([INV-12](../../../docs/02-architecture/architecture-constitution.md)),
    # so a tenant can publish a fix at 10:00 while a run started at 09:00
    # continues on the instructions it began with.
    #
    # The alternative — runs following the definition — mutates a running
    # program's instructions. The resulting damage is silent, unbounded, and
    # extremely hard to reconstruct afterwards, because the evidence of what the
    # program *was* has been overwritten.
    class Definition
      Error = Class.new(StandardError)
      NotFound = Class.new(Error)
      InvalidDefinition = Class.new(Error)

      # A step graph is data, so it is validated as data. This is the minimum
      # that makes a definition executable at all; richer validation (reachable
      # steps, type-checked arguments) belongs with the step catalogue.
      REQUIRED_STEP_KEYS = %w[key type].freeze

      class << self
        def create!(key:, name:, description: nil, created_by_membership_id: nil)
          Internal::Models::WorkflowDefinition.create!(
            key: key, name: name, description: description,
            created_by_membership_id: created_by_membership_id
          )
        end

        # Publish a new immutable version of `definition`.
        #
        # @return [Internal::Models::WorkflowVersion]
        def publish!(key:, definition:, published_by_membership_id: nil)
          record = find!(key)
          validate!(definition)

          version = ActiveRecord::Base.transaction(requires_new: true) do
            next_number = (record.versions.maximum(:version) || 0) + 1

            record.versions.create!(
              organization_id: record.organization_id,
              version: next_number,
              definition: definition,
              checksum: Internal::Models::WorkflowVersion.checksum_for(definition),
              published_at: Time.current,
              published_by_membership_id: published_by_membership_id
            ).tap { record.update!(status: "active") }
          end

          version
        end

        def find!(key)
          Internal::Models::WorkflowDefinition.find_by(key: key) ||
            raise(NotFound, "no workflow definition `#{key}` in this tenant")
        end

        # The version a new run should be pinned to. A definition with no
        # published version cannot be triggered — refusing here is better than
        # starting a run with nothing to execute.
        def version_for_new_run!(key)
          record = find!(key)
          record.published_version ||
            raise(NotFound, "workflow `#{key}` has no published version to run")
        end

        def validate!(definition)
          steps = definition.is_a?(Hash) ? definition["steps"] || definition[:steps] : nil
          raise InvalidDefinition, "definition must contain a `steps` array" unless steps.is_a?(Array)
          raise InvalidDefinition, "a definition must contain at least one step" if steps.empty?

          steps.each_with_index do |step, index|
            missing = REQUIRED_STEP_KEYS.reject { |k| step.is_a?(Hash) && step[k].present? }
            next if missing.empty?

            raise InvalidDefinition, "step #{index} is missing #{missing.join(', ')}"
          end

          duplicate = steps.map { |s| s["key"] }.tally.find { |_k, n| n > 1 }
          raise InvalidDefinition, "duplicate step key `#{duplicate.first}`" if duplicate

          true
        end
      end
    end
  end
end
