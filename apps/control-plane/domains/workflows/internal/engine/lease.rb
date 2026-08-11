# frozen_string_literal: true

module Nexus
  module Workflows
    module Internal
      module Engine
        # Leases, not locks (ADR-006).
        #
        # A lock is held until it is released. A worker killed mid-step — which
        # happens on every deploy, by design — never releases it, and the run is
        # stuck until a human notices. There is no timeout on a lock that would
        # not also be a lease, so the honest thing is to build the lease.
        #
        # THREE PROPERTIES, EACH LOAD-BEARING
        #
        # **Expiry uses the database's clock.** `expires_at > now()` is
        # evaluated by PostgreSQL, never compared against `Time.current` in a
        # worker. A worker whose clock is two minutes fast would otherwise
        # believe it still holds a lease the database has already given away —
        # and two workers executing the same step is precisely what the lease
        # exists to prevent.
        #
        # **Reclaim is a claim, not a cleanup.** Nothing sweeps expired leases
        # on a timer. The next worker that wants the run takes it, atomically,
        # because a sweeper is another process that can itself be dead.
        #
        # **A fence token increases monotonically.** A worker that was paused
        # long enough to lose its lease can wake up and try to write. The token
        # it holds is now stale, so its writes are rejected rather than silently
        # accepted — which is the difference between a bounded incident and
        # corrupt run state.
        class Lease
          Lost = Class.new(StandardError)

          # NFR-105 budgets 30 s for recovery after worker loss, so the lease
          # must expire well inside that. Renewal is the worker's job while it
          # is genuinely working.
          DURATION = 20.seconds

          Held = Struct.new(:run_id, :worker_id, :fence_token, :expires_at, keyword_init: true)

          class << self
            # Acquire the run's lease, or take it over if the previous holder's
            # has expired. One UPDATE, so two workers racing produce one winner.
            #
            # @return [Held, nil] nil when another worker holds a live lease
            def acquire(run_id:, worker_id:, duration: DURATION)
              existing = Models::RunLease.find_by(workflow_run_id: run_id)

              if existing.nil?
                created = Models::RunLease.create!(
                  workflow_run_id: run_id, worker_id: worker_id, fence_token: 1,
                  acquired_at: Time.current, expires_at: duration.from_now
                )
                return to_held(created)
              end

              # `expired` is a database predicate: the row is only taken if
              # PostgreSQL agrees it is dead.
              claimed = Models::RunLease.expired.where(id: existing.id).update_all(
                worker_id: worker_id,
                fence_token: Arel.sql("fence_token + 1"),
                acquired_at: Time.current,
                expires_at: Arel.sql("now() + interval '#{duration.to_i} seconds'"),
                updated_at: Time.current
              )

              claimed.zero? ? nil : to_held(existing.reload)
            rescue ActiveRecord::RecordNotUnique
              # Another worker created the lease between the read and the write.
              # It won; we did not.
              nil
            end

            # Extend a lease we still hold. Fails if we lost it — which is the
            # signal to stop working, not to try harder.
            def renew!(held, duration: DURATION)
              updated = Models::RunLease
                        .where(workflow_run_id: held.run_id, worker_id: held.worker_id,
                               fence_token: held.fence_token)
                        .update_all(expires_at: Arel.sql("now() + interval '#{duration.to_i} seconds'"),
                                    updated_at: Time.current)

              raise Lost, lost_message(held) if updated.zero?

              held
            end

            # Assert we still hold the lease before writing anything durable.
            # This is the fence: a resumed zombie worker's token is stale, so
            # its write is refused instead of corrupting the run.
            def assert_held!(held)
              live = Models::RunLease.live.exists?(
                workflow_run_id: held.run_id, worker_id: held.worker_id, fence_token: held.fence_token
              )
              raise Lost, lost_message(held) unless live

              true
            end

            def release!(held)
              Models::RunLease.where(workflow_run_id: held.run_id, worker_id: held.worker_id,
                                     fence_token: held.fence_token).delete_all
            end

            def held_by(run_id:) = Models::RunLease.live.find_by(workflow_run_id: run_id)&.worker_id

            private

            def to_held(record)
              Held.new(run_id: record.workflow_run_id, worker_id: record.worker_id,
                       fence_token: record.fence_token, expires_at: record.expires_at)
            end

            def lost_message(held)
              "worker #{held.worker_id} no longer holds run #{held.run_id} at fence #{held.fence_token}. " \
                "Another worker reclaimed it after this lease expired — stop working on this run. " \
                "Its writes are authoritative; yours are not."
            end
          end
        end
      end
    end
  end
end
