# frozen_string_literal: true

module Nexus
  module Events
    # Published contract: re-deliver events that are already in the log (FR-208).
    #
    # Replay is a hard requirement, and it is the reason the event *store* and
    # the durable log exist at all rather than trusting a broker's retention
    # (ADR-003). It is used to rebuild a projection, to recover from a handler
    # bug, and to bring a new consumer up on history it never saw.
    #
    # THE DEDUP TRAP
    #
    # Naively rewinding a cursor does nothing. The inbox has already claimed
    # every dedup key for that group, so the replayed events are recognized as
    # duplicates and dropped — the replay reports success and changes nothing,
    # which is the worst possible outcome for an operation someone reaches for
    # during an incident.
    #
    # There are exactly two correct ways out, and both are offered explicitly:
    #
    #   into_group   Replay into a NEW consumer group. Inbox keys are scoped by
    #                group, so a fresh group sees clean history. This is the
    #                default and the safe one — the old group keeps running.
    #
    #   reprocess!   Replay into the SAME group, purging its inbox claims first.
    #                Correct only when the handler is genuinely idempotent
    #                against its own past effects, which is a stronger claim
    #                than idempotent against duplicates. It asks for that claim
    #                by name.
    class Replay
      Refused = Class.new(StandardError)

      class << self
        # Point a new consumer group at history from `from_position` onward.
        # Nothing is copied: the log already holds the events, so a replay is a
        # cursor operation, not a data operation.
        #
        # @return [Integer] partitions rewound
        def into_group(target_group:, organization_id:, topic: Relay::DEFAULT_TOPIC, from_position: 0)
          within_tenant(organization_id) do
            (0...Transport::PARTITIONS).each do |partition|
              Transport.current.seek(group: target_group, topic: topic,
                                     partition_number: partition, position: from_position)
            end
            Transport::PARTITIONS
          end
        end

        # Replay into an existing group. Purges that group's inbox claims so the
        # events are not deduplicated away.
        #
        # `i_understand_handlers_will_rerun:` is a required keyword rather than
        # a boolean with a default, because the difference between this and
        # `into_group` is whether side effects happen a second time — and that
        # is not a decision to make by accident at 3am.
        def reprocess!(group:, organization_id:, topic: Relay::DEFAULT_TOPIC,
                       from_position: 0, i_understand_handlers_will_rerun: false)
          unless i_understand_handlers_will_rerun
            raise Refused,
                  "reprocess! re-runs handlers against events they have already processed. " \
                  "If the handler is idempotent against its own past effects, pass " \
                  "i_understand_handlers_will_rerun: true. If you only need to rebuild a read " \
                  "model, use into_group with a fresh group name instead — it is reversible."
          end

          within_tenant(organization_id) do
            purged = Internal::Models::InboxMessage.where(consumer_group: group).delete_all

            (0...Transport::PARTITIONS).each do |partition|
              Transport.current.seek(group: group, topic: topic,
                                     partition_number: partition, position: from_position)
            end

            purged
          end
        end

        # Return dead letters to the log's flow by clearing their claims and
        # rewinding. A dead letter that cannot be replayed is an error log with
        # extra steps, which is why the full payload is stored.
        #
        # @return [Integer] dead letters marked for replay
        def dead_letters(group:, organization_id:)
          within_tenant(organization_id) do
            letters = Internal::Models::DeadLetterMessage.unreplayed.where(consumer_group: group).to_a
            return 0 if letters.empty?

            keys = letters.filter_map { |l| l.metadata["event_id"] }
            Internal::Models::InboxMessage.where(consumer_group: group, dedup_key: keys).delete_all
            letters.each { |l| l.update!(replayed_at: Time.current) }

            letters.size
          end
        end

        private

        def within_tenant(organization_id, &block)
          ActiveRecord::Base.transaction(requires_new: true) do
            Tenancy::Context.with(organization_id: organization_id) do
              Database::RowLevelSecurity.apply!
              block.call
            end
          end
        end
      end
    end
  end
end
