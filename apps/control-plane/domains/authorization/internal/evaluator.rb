# frozen_string_literal: true

module Nexus
  module Authorization
    module Internal
      # The decision procedure. Four stages, in this order, and the order is the
      # security property:
      #
      #   1. Is this a permission the platform actually defines?
      #   2. Does the principal's effective set (INV-16) contain it?
      #   3. Does any tenant policy refine that answer? (deny wins)
      #   4. Otherwise: allow.
      #
      # Stage 1 exists so that a typo cannot become a permission. `Authorize`
      # calls are written by hand all over the codebase; without a catalog check,
      # `:aprove` would be a permission nobody holds — a silent denial that looks
      # like a grant bug — and, worse, a future wildcard or prefix rule could turn
      # an unrecognized string into an unintended allow.
      #
      # Stage 3 can only ever narrow stage 2's answer. See Policy.
      class Evaluator
        def call(principal, action, resource_type, attributes: {})
          permission_key = "#{resource_type}.#{action}"

          unless Catalog.key?(permission_key)
            return deny(permission_key, :undefined_permission,
                        "`#{permission_key}` is not in the permission catalog")
          end

          set = PermissionSet.effective_for(principal, attributes: attributes)

          unless set.include?(permission_key)
            return deny(permission_key, :no_grant,
                        "no role held by this principal carries `#{permission_key}`")
          end

          request = Policy::Request.new(
            permission_key: permission_key,
            resource_type: resource_type.to_s,
            action: action.to_s,
            risk_tier: Catalog.risk_tier(permission_key),
            attributes: attributes
          )

          decisive = Policy.for_current_tenant.find { |policy| policy.matches?(request) }

          if decisive&.deny?
            return deny(permission_key, :policy_denied,
                        "policy `#{decisive.name}` denies this request", policy_id: decisive.id)
          end

          allow(permission_key, policy_id: decisive&.id)
        end

        private

        def allow(permission_key, policy_id: nil)
          Authorize::Decision.new(
            allowed: true, permission: permission_key, reason: :granted,
            message: "granted", policy_id: policy_id
          )
        end

        def deny(permission_key, reason, message, policy_id: nil)
          Authorize::Decision.new(
            allowed: false, permission: permission_key, reason: reason,
            message: message, policy_id: policy_id
          )
        end
      end
    end
  end
end
