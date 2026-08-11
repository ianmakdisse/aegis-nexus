# frozen_string_literal: true

module Nexus
  module Events
    # Published contract: the base class every event handler subclasses
    # (role: `consumer`).
    #
    #     class ProjectOrders < Nexus::Events::Consumer
    #       consumes topic: "nexus.events", group: "orders-projector"
    #
    #       def dedup_key(envelope) = envelope.event_id
    #       def handle(envelope) = …
    #     end
    #
    # THE BASE CLASS REFUSES TO RUN A HANDLER WITHOUT A DEDUP KEY
    #
    # This is INV-05's enforcement, and it is a refusal rather than a warning
    # because delivery is at-least-once by construction. Duplicates *will*
    # arrive; the only question is whether they are harmless. A handler with no
    # dedup key is not "probably fine" — it is a latent double-charge, a double
    # notification, or a double side effect waiting for a relay restart.
    #
    # WHY THE CLAIM AND THE HANDLER SHARE ONE TRANSACTION
    #
    # The obvious implementation writes the inbox row, then calls the handler.
    # If the handler then fails, the claim survives — and every retry is
    # deduplicated away. The message is silently and permanently dropped, which
    # is worse than the duplicate the inbox existed to prevent.
    #
    # So both happen in one transaction. A failed handler rolls the claim back
    # and the message is genuinely retryable; a successful one commits both.
    class Consumer
      MissingDedupKey = Class.new(StandardError)
      NotConfigured = Class.new(StandardError)

      # In-process retries before a message is dead-lettered. Durable backoff
      # belongs to the scheduler (`scheduled_jobs`, Phase 7); this is the
      # immediate-retry budget, not a substitute for it.
      MAX_ATTEMPTS = 3

      Result = Struct.new(:processed, :duplicates, :dead_lettered, keyword_init: true)

      class << self
        attr_reader :topic_name, :group_name

        # Which process role runs this consumer. `api` pods must not run
        # consumers and a projector must not run ordinary handlers — a role that
        # quietly runs someone else's work multiplies concurrency on the next
        # deploy that scales it (roles.yml).
        def role = :consumer

        # A base class that exists to be subclassed is not itself a consumer.
        # Marked explicitly rather than inferred from "has no topic", so a real
        # subclass that forgot `consumes` still fails loudly instead of being
        # quietly skipped by the role that was supposed to run it.
        def abstract! = @abstract = true
        def abstract? = @abstract == true

        def registry_for(role)
          registry.reject(&:abstract?).select { |consumer| consumer.role == role }
        end

        # Subclasses are collected so the `consumer` role can boot all of them
        # without a registry file that someone forgets to update.
        def registry = @registry ||= []

        def inherited(subclass)
          super
          Consumer.registry << subclass
        end

        def consumes(topic:, group:)
          @topic_name = topic
          @group_name = group
        end

        # Drain one tenant, for this consumer.
        def consume(organization_id:, limit: 100)
          new.consume(organization_id: organization_id, limit: limit)
        end

        # The `consumer` role's entry point (bin/role-entrypoint). Runs every
        # registered consumer for every tenant, enumerated from the platform
        # directory (ADR-013) for the same reason the relay does.
        def run!(tenant_source: nil, interval: 1.0)
          loop do
            total = Relay.each_tenant_id(tenant_source).sum do |id|
              registry_for(:consumer).sum { |consumer| consumer.consume(organization_id: id).processed }
            end
            sleep(interval) if total.zero?
          end
        end
      end

      # @return [Result]
      def consume(organization_id:, limit: 100)
        assert_configured!
        result = Result.new(processed: 0, duplicates: 0, dead_lettered: 0)

        Tenancy::Context.with(organization_id: organization_id) do
          entries = read_entries(limit)

          entries.each do |entry|
            case deliver(entry)
            when :processed then result.processed += 1
            when :duplicate then result.duplicates += 1
            when :dead_lettered then result.dead_lettered += 1
            end
          end
        end

        result
      end

      # Subclasses must implement both. Neither has a default: a default dedup
      # key would be a guess about idempotency, and a default handler would
      # silently discard events.
      def dedup_key(_envelope)
        raise MissingDedupKey,
              "#{self.class} must implement #dedup_key. Delivery is at-least-once (INV-05), so a " \
              "handler with no dedup key is a duplicate side effect waiting for a relay restart. " \
              "Derive the key from something durable — the event id, or the aggregate id plus a version."
      end

      def handle(_envelope)
        raise NotImplementedError, "#{self.class} must implement #handle(envelope)"
      end

      private

      def group = self.class.group_name
      def topic = self.class.topic_name

      def assert_configured!
        return if topic.present? && group.present?

        raise NotConfigured, "#{self.class} must declare `consumes topic:, group:`"
      end

      def read_entries(limit)
        ActiveRecord::Base.transaction(requires_new: true) do
          Database::RowLevelSecurity.apply!
          Transport.current.read(group: group, topic: topic, limit: limit)
        end
      end

      # @return [Symbol] :processed | :duplicate | :dead_lettered
      def deliver(entry)
        envelope = Envelope.from_headers(
          entry.headers.merge("partition_key" => entry.partition_key), entry.payload
        )
        key = dedup_key(envelope)
        raise MissingDedupKey, "#{self.class}#dedup_key returned blank for #{envelope.event_type}" if key.blank?

        attempt(entry, envelope, key)
      end

      def attempt(entry, envelope, key)
        attempts = 0

        begin
          attempts += 1
          outcome = process_once(entry, envelope, key)
          commit_cursor(entry)
          outcome
        rescue StandardError => e
          retry if attempts < MAX_ATTEMPTS

          dead_letter!(entry, envelope, e, attempts)
          # The cursor advances past a dead letter on purpose. Leaving it in
          # place would block the partition forever on one poison message,
          # turning a single bad event into a tenant-wide outage.
          commit_cursor(entry)
          :dead_lettered
        end
      end

      # Claim and handle, atomically. See the class comment for why.
      def process_once(entry, envelope, key)
        ActiveRecord::Base.transaction(requires_new: true) do
          Database::RowLevelSecurity.apply!

          unless Internal::Models::InboxMessage.claim(
            consumer_group: group, dedup_key: key, event_type: envelope.event_type
          )
            next :duplicate
          end

          handle(envelope)
          :processed
        end
      end

      def commit_cursor(entry)
        ActiveRecord::Base.transaction(requires_new: true) do
          Database::RowLevelSecurity.apply!
          Transport.current.commit(group: group, topic: entry.topic,
                                   partition_number: entry.partition_number, position: entry.position)
        end
      end

      def dead_letter!(entry, envelope, error, attempts)
        ActiveRecord::Base.transaction(requires_new: true) do
          Database::RowLevelSecurity.apply!
          Internal::Models::DeadLetterMessage.create!(
            consumer_group: group,
            event_type: envelope.event_type,
            payload: entry.payload,
            metadata: entry.headers,
            error_class: error.class.name,
            error_message: error.message,
            attempts: attempts,
            failed_at: Time.current
          )
        end

        Rails.logger.error(
          "[events] dead-lettered #{envelope.event_type} for #{group} after #{attempts} attempts: " \
          "#{error.class}: #{error.message}"
        )
      end
    end
  end
end
