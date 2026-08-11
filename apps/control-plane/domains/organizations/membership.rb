# frozen_string_literal: true

module Nexus
  module Organizations
    # Published contract: the link between a global user and one tenant.
    #
    # Identity needs this to build a principal — a membership id is what
    # Authorization binds grants to — and INV-01 forbids Identity from reading
    # `memberships` itself. So Organizations publishes the question rather than
    # the table, and returns a value object rather than an ActiveRecord object:
    # handing out a model would hand out `update!` and a live connection to a
    # table the caller is not allowed to touch.
    #
    # Every query here runs inside the caller's tenant context and is therefore
    # RLS-scoped. There is deliberately NO "which organizations does this user
    # belong to?" operation: answering it requires reading memberships across
    # tenants, which the isolation model forbids by construction. Tenant
    # selection comes from the request (subdomain or slug) and is *verified*
    # here — which is the safe direction.
    class Membership
      ACTIVE = "active"

      Record = Struct.new(:id, :user_id, :organization_id, :status, keyword_init: true) do
        def active? = status == ACTIVE
      end

      class << self
        # The user's membership in the tenant whose context is open, or nil.
        def for_user(user_id:)
          record = Internal::Models::Membership.find_by(user_id: user_id)
          return nil if record.nil?

          Record.new(id: record.id, user_id: record.user_id,
                     organization_id: record.organization_id, status: record.status)
        end

        # nil unless the membership exists AND is active. A membership that has
        # been suspended is not a membership for authentication purposes, and
        # collapsing the two states here means no caller can forget to check.
        def active_for_user(user_id:)
          record = for_user(user_id: user_id)
          record&.active? ? record : nil
        end

        def member?(user_id:) = !active_for_user(user_id: user_id).nil?
      end
    end
  end
end
