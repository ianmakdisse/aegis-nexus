# frozen_string_literal: true

module Nexus
  module Identity
    module Internal
      module Models
        # A refresh-token session. Tenant-scoped and RLS-protected: a session is
        # authority inside one organization, even though the user it belongs to
        # is global.
        #
        # The row IS the refresh token — there is no separate token table. The
        # plaintext is never stored; `refresh_token_digest` is a SHA-256 of a
        # 256-bit random value, and the unique index on it is what makes reuse
        # detection a lookup rather than a scan.
        #
        # `family_id` groups every rotation of one login. Rotation writes a new
        # row with the same family and revokes the old one, so a replayed token
        # resolves to an already-revoked row — which is the signal that it was
        # stolen (ADR-011).
        class Session < TenantScopedRecord
          self.table_name = "sessions"

          validates :user_id, :refresh_token_digest, :family_id, :expires_at, presence: true

          # Expiry uses the database's clock, not the worker's. A process with a
          # skewed clock must not be able to honor a session the database
          # considers dead.
          scope :live, -> { where(revoked_at: nil).where("expires_at > now()") }
          scope :in_family, ->(family_id) { where(family_id: family_id) }

          def revoked? = revoked_at.present?

          def revoke!(at: Time.current)
            return if revoked?

            update!(revoked_at: at)
          end
        end
      end
    end
  end
end
