# frozen_string_literal: true

module Nexus
  module Events
    # Published contract: the outbox relay (role: `relay`).
    #
    # Drains committed outbox rows onto the backbone. Starving this role delays
    # everything downstream while producing no errors at all, which is why the
    # role scales on the AGE of the oldest unpublished row rather than on depth.
    #
    # WHY PUBLISH-THEN-MARK IS NOT ATOMIC, EVEN THOUGH IT COULD BE HERE
    #
    # With the PostgreSQL transport, writing the log entry and marking the outbox
    # row could share one transaction — which would make publication
    # exactly-once for that transport. It deliberately does not.
    #
    # Kafka cannot offer that, so an atomic relay would behave differently on
    # each transport, and the duplicate path — the one that actually runs in
    # production — would never be exercised in CI. We would be testing a
    # guarantee we do not have. Instead the relay publishes, then marks, and a
    # crash between the two republishes on restart. The unique index on
    # `(organization_id, outbox_message_id)` in the log absorbs it.
    #
    # This is [INV-06](../../../docs/02-architecture/architecture-constitution.md)
    # in one method: at-least-once delivery, never a claim of exactly-once.
    class Relay
      DEFAULT_BATCH = 100
      DEFAULT_TOPIC = "nexus.events"

      TenantEnumerationUnavailable = Class.new(StandardError)

      class << self
        # Drain one tenant's outbox. This is the whole mechanism; `run!` is a
        # loop around it.
        #
        # @return [Integer] messages published
        def drain(organization_id:, batch_size: DEFAULT_BATCH, topic: DEFAULT_TOPIC)
          published = 0

          Tenancy::Context.with(organization_id: organization_id) do
            ActiveRecord::Base.transaction(requires_new: true) do
              Database::RowLevelSecurity.apply!

              Internal::Models::OutboxMessage.unpublished.limit(batch_size).each do |message|
                published += 1 if publish_one(message, topic)
              end
            end
          end

          published
        end

        # The `relay` role's entry point (bin/role-entrypoint).
        #
        # Requires a source of tenant ids. There is deliberately no default: the
        # set of tenants cannot be read from the database by any application
        # role, because `organizations` is itself RLS-protected and no role
        # bypasses policy (INV-14). Enumerating tenants is an unresolved
        # architectural question — see the Phase 5 notes in project-state.md.
        # Guessing at it here would either invent a privileged role or silently
        # relay for nobody.
        def run!(tenant_source: nil, interval: 1.0, topic: DEFAULT_TOPIC)
          ids = tenant_source || (raise TenantEnumerationUnavailable, tenant_enumeration_message)

          loop do
            total = Array(ids.respond_to?(:call) ? ids.call : ids)
                    .sum { |id| drain(organization_id: id, topic: topic) }
            sleep(interval) if total.zero?
          end
        end

        private

        # @return [Boolean] whether this call published the message
        def publish_one(message, topic)
          entry_id = Transport.current.publish(
            topic: topic,
            key: message.partition_key,
            payload: message.payload,
            headers: message.metadata.merge("event_type" => message.event_type,
                                            "version" => message.event_version),
            outbox_message_id: message.id
          )

          # nil means the log already held this message — a previous attempt
          # published and crashed before marking. Marking it now is the recovery,
          # not a duplicate.
          message.update!(published_at: Time.current, attempts: message.attempts + 1)
          !entry_id.nil?
        rescue StandardError => e
          # A publish failure leaves the row unpublished, which is the correct
          # outcome: the relay will try again. Recording the error makes a
          # permanently stuck message visible rather than merely slow.
          message.update!(attempts: message.attempts + 1, last_error: "#{e.class}: #{e.message}")
          raise
        end

        def tenant_enumeration_message
          "Relay.run! needs a tenant source. `organizations` is RLS-protected and no application " \
            "role may bypass policy, so the list of tenants cannot be read from the database. " \
            "Pass tenant_source: (an array or callable of organization ids) until the platform " \
            "tenant directory is decided."
        end
      end
    end
  end
end
