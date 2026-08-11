# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)

# Root namespace must exist before Zeitwerk is told about it.
require_relative "../lib/nexus"

# Migration helpers are required rather than autoloaded: migrations run in a
# context where the autoloader may not have been set up yet, and a missing
# constant there fails a deploy rather than a request.
require_relative "../lib/nexus/migration/tenancy"

module ControlPlane
  class Application < Rails::Application
    config.load_defaults 7.1

    # ---- Module layout ----------------------------------------------------
    # ADR-001: one codebase, hard internal boundaries. `domains/` and
    # `infrastructure/` sit outside `app/` so they can carry the Nexus root
    # namespace (see lib/nexus.rb) and so the split between "delivery" and
    # "business" is structural rather than conventional.
    #
    # Boundaries between the directories under domains/ are enforced by
    # tools/boundary-check (INV-01, INV-02, INV-03).
    Rails.autoloaders.main.push_dir("#{root}/domains", namespace: Nexus)
    Rails.autoloaders.main.push_dir("#{root}/infrastructure", namespace: Nexus)

    config.eager_load_paths << "#{root}/domains"
    config.eager_load_paths << "#{root}/infrastructure"

    # ---- API posture ------------------------------------------------------
    config.api_only = true
    config.active_job.queue_adapter = :async # replaced by the durable queue in Phase 5

    # ---- Time and encoding ------------------------------------------------
    # UTC everywhere. Local time in a distributed system is a correctness bug
    # waiting for a DST transition (see INV-09 on ordering).
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc

    # ---- Process role -----------------------------------------------------
    # One image, many roles (ADR-001). The role decides which subsystems boot:
    # an `api` pod must not start consumers, and a `worker` pod must not bind a
    # port. Roles are declared in config/roles.yml.
    config.x.role = ENV.fetch("NEXUS_ROLE", "api")

    # ---- Tenancy ----------------------------------------------------------
    # INV-14 layer (c): tenant context is request/job scoped and fails closed.
    # This flag exists so tests can prove the other two layers still deny when
    # this one is disabled.
    config.x.tenancy.enforce_context = ENV.fetch("NEXUS_ENFORCE_TENANT_CONTEXT", "true") == "true"

    # ---- Event backbone ---------------------------------------------------
    # ADR-003: transport is pluggable. `postgres` runs the full event path with
    # no broker, which is what makes duplicate-delivery and replay tests
    # runnable in CI.
    config.x.events.transport = ENV.fetch("NEXUS_EVENT_TRANSPORT", "postgres")

    config.generators do |g|
      g.test_framework :rspec
      g.helper false
      g.assets false
    end
  end
end
