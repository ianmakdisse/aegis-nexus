# frozen_string_literal: true

module Nexus
  module Tenancy
    # Isolation layer (c) of INV-14: request/job-scoped tenant context that
    # FAILS CLOSED when absent.
    #
    # The single most important property of this class is what it does when it
    # has no tenant: it raises. It does not return nil, and it does not return an
    # unscoped relation. An empty result set is indistinguishable from "this
    # tenant has no data", which is exactly the lie that turns a missing filter
    # into a silent cross-tenant read.
    #
    # Storage is per-Fiber (ActiveSupport::CurrentAttributes semantics via a
    # Fiber-local) so that concurrent requests in a threaded server, and Fibers
    # inside a job, cannot observe each other's tenant.
    #
    #   Tenancy::Context.with(organization_id: id) { ... }   # scoped block
    #   Tenancy::Context.organization_id                     # raises if unset
    #   Tenancy::Context.organization_id!                    # explicit, same
    #   Tenancy::Context.current                             # nil-safe peek
    #
    # See: docs/08-security/tenant-isolation.md, ADR-009.
    class Context
      Missing = Class.new(StandardError)
      Conflict = Class.new(StandardError)

      KEY = :nexus_tenant_context

      class << self
        # Establish tenant context for the duration of the block.
        #
        # Nesting with a *different* tenant raises rather than silently
        # shadowing: a nested re-scope almost always means two tenants' work got
        # interleaved, and the correct response is to fail loudly.
        def with(organization_id:, principal_id: nil, placement: nil)
          raise ArgumentError, "organization_id is required" if organization_id.nil?

          previous = current
          if previous && previous[:organization_id] != organization_id
            raise Conflict,
                  "nested tenant context change #{previous[:organization_id]} -> #{organization_id}; " \
                  "finish or explicitly reset the outer context first"
          end

          Thread.current[KEY] = {
            organization_id: organization_id,
            principal_id: principal_id,
            placement: placement
          }.freeze

          yield
        ensure
          Thread.current[KEY] = previous
        end

        # Run with no tenant. Only legitimate for genuinely platform-global work
        # (migrations, region registry, cross-tenant maintenance jobs). Named
        # verbosely so it is obvious in review and greppable in an audit.
        def without_tenant_for_platform_operation
          previous = current
          Thread.current[KEY] = nil
          yield
        ensure
          Thread.current[KEY] = previous
        end

        def current
          Thread.current[KEY]
        end

        def present?
          !current.nil?
        end

        # The accessor domain code uses. Raises when unset — see class comment.
        def organization_id
          ctx = current
          raise Missing, missing_message if ctx.nil?

          ctx[:organization_id]
        end
        alias organization_id! organization_id

        def principal_id
          current&.fetch(:principal_id, nil)
        end

        def placement
          current&.fetch(:placement, nil)
        end

        # Enforcement can be disabled ONLY so the isolation suite can prove the
        # other two layers still deny on their own (INV-14 requires each layer to
        # fail independently). Never disabled anywhere a human can reach.
        def enforced?
          Rails.application.config.x.tenancy.enforce_context
        end

        private

        def missing_message
          "no tenant context (INV-14 layer c). Every operation touching business data must run inside " \
            "Nexus::Tenancy::Context.with(organization_id:). If this is genuinely platform-global work, " \
            "use without_tenant_for_platform_operation and justify it in review."
        end
      end
    end
  end
end
