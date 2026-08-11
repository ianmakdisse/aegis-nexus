# frozen_string_literal: true

module Nexus
  module Agents
    class Leaky
      def timeline(run_id)
        Nexus::Workflows::Internal::RunRepository.find(run_id)
      end

      def counts
        ActiveRecord::Base.connection.execute("SELECT count(*) FROM workflow_runs")
      end

      def publish(msg)
        Kafka.produce(msg)
      end
    end
  end
end
