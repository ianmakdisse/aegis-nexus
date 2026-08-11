# frozen_string_literal: true

module Nexus
  module Identity
    module Internal
      module Models
        # Users are GLOBAL, not tenant-scoped: one human may belong to several
        # organizations, and duplicating accounts per tenant breaks SSO identity
        # and makes "who is this person" unanswerable. Access to a user is
        # mediated by memberships, which ARE tenant-scoped and RLS-protected.
        #
        # A consequence worth stating: there is no "list the organizations I
        # belong to" query anywhere in this system. It would have to read
        # memberships across tenants, which RLS forbids by construction. Tenant
        # selection therefore comes from the request (subdomain or slug) and is
        # verified against a membership — see Identity::IssueToken.
        class User < ApplicationRecord
          self.table_name = "users"

          # `validations: false` because password_digest is nullable: an SSO-only
          # or invited-but-not-yet-activated user legitimately has no password,
          # and the default validations would make those rows unsavable.
          has_secure_password validations: false

          STATUSES = %w[active disabled].freeze

          validates :email, presence: true
          validates :status, inclusion: { in: STATUSES }

          # Case-insensitive by the unique functional index on lower(email).
          # Matching in SQL rather than in Ruby keeps the lookup on that index.
          scope :with_email, ->(email) { where("lower(email) = lower(?)", email.to_s) }

          def active? = status == "active"

          def password_set? = password_digest.present?
        end
      end
    end
  end
end
