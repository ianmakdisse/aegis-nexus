# frozen_string_literal: true

module Nexus
  module Workflows
    # Published contract: start and inspect workflow runs.
    #
    # A run is pinned to a workflow **version**, never to a definition
    # (INV-12). Everything else about the engine can be rewritten; that pin is
    # what makes publishing a fix safe while runs are in flight.
    class Run
      Error = Class.new(StandardError)
      NotFound = Class.new(Error)

      Record = Struct.new(:id, :status, :workflow_version_id, :input, :output, :error,
                          :correlation_id, :started_at, :finished_at, keyword_init: true) do
        def terminal? = Internal::Models::WorkflowRun::TERMINAL.include?(status)
        def waiting? = %w[sleeping waiting_approval].include?(status)
      end

      class << self
        # Start a run against the definition's currently published version.
        #
        # Idempotent on `idempotency_key`: the same trigger — a redelivered
        # event, a retried API call — yields the same run rather than a second
        # one. Delivery is at-least-once (INV-05), so a trigger without a key
        # is a workflow that runs twice on the next relay restart.
        def start!(definition_key:, input: {}, idempotency_key: nil, correlation_id: nil, trigger_source: "api")
          version = Definition.version_for_new_run!(definition_key)

          existing = idempotency_key && Internal::Models::WorkflowRun.find_by(idempotency_key: idempotency_key)
          return to_record(existing) if existing

          record = Internal::Models::WorkflowRun.create!(
            workflow_version_id: version.id,
            status: "pending",
            input: input,
            idempotency_key: idempotency_key,
            trigger_source: trigger_source,
            correlation_id: correlation_id || SecureRandom.uuid,
            started_at: Time.current
          )

          to_record(record)
        rescue ActiveRecord::RecordNotUnique
          # Two triggers raced on the same key. The other one won, and its run
          # is the answer — returning it is the whole point of the key.
          to_record(Internal::Models::WorkflowRun.find_by!(idempotency_key: idempotency_key))
        end

        def find!(id)
          record = Internal::Models::WorkflowRun.find_by(id: id)
          raise NotFound, "no run #{id} in this tenant" if record.nil?

          to_record(record)
        end

        # The definition this run is executing — read through its pinned
        # version, so it is what the run started with even if the definition has
        # since been republished.
        def definition_for(id)
          run = Internal::Models::WorkflowRun.find_by(id: id) || raise(NotFound, "no run #{id}")
          version = Internal::Models::WorkflowVersion.find(run.workflow_version_id)

          # A version row mutated in place would silently change a running
          # program's instructions — the one thing INV-12 forbids and the
          # database cannot prevent on its own.
          raise Error, "workflow version #{version.id} failed its checksum" unless version.intact?

          version.definition
        end

        def to_record(record)
          Record.new(
            id: record.id, status: record.status, workflow_version_id: record.workflow_version_id,
            input: record.input, output: record.output, error: record.error,
            correlation_id: record.correlation_id, started_at: record.started_at,
            finished_at: record.finished_at
          )
        end
      end
    end
  end
end
