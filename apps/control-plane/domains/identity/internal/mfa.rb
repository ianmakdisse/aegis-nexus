# frozen_string_literal: true

require "rotp"

module Nexus
  module Identity
    module Internal
      # TOTP second factor (FR-105).
      #
      # THE REPLAY WINDOW
      #
      # A TOTP code is valid for a 30-second step, which means a code observed by
      # an attacker — shoulder-surfed, phished, or read out of a proxy log — can
      # be replayed for the remainder of that step unless the server refuses to
      # accept the same interval twice. Most implementations skip this and are
      # quietly weaker than users assume.
      #
      # `verify` therefore passes `after:` to rotp, which rejects any code from an
      # interval at or before the user's last successful authentication, and
      # `users.last_authenticated_at` is advanced on every success. The column
      # already existed for audit; it is load-bearing for security too.
      #
      # ENCRYPTION AT REST (INV-18)
      #
      # The shared secret is a credential: anyone holding it can generate valid
      # codes forever. It is encrypted with a key derived from the application's
      # own secret and never assigned to a loggable attribute.
      #
      # This is application-level encryption, NOT envelope encryption with a real
      # KMS — which is what INV-18 ultimately requires and what unresolved
      # question Q1 is about. The gap is real and recorded as TD-007. What it
      # buys today: a stolen database dump does not yield working second factors.
      # What it does not buy: protection from an attacker who has the application
      # secret, and no crypto-shredding story.
      module Mfa
        DRIFT = 30 # seconds of tolerated clock skew, one step either way
        ENCRYPTION_PURPOSE = "nexus/identity/mfa-secret"

        module_function

        def enabled?(user)
          user.mfa_enabled_at.present? && user.mfa_secret_ciphertext.present?
        end

        # Returns the plaintext secret exactly once, for the enrollment QR code.
        # MFA is not active until `enable!` confirms the user can produce a code
        # from it — enrolling on the strength of a generated secret alone locks
        # out anyone whose authenticator app failed to save it.
        def provision!(user)
          secret = ROTP::Base32.random
          user.update!(mfa_secret_ciphertext: encrypt(secret), mfa_enabled_at: nil)
          secret
        end

        def enable!(user, code)
          return false unless user.mfa_secret_ciphertext.present?
          return false unless totp(user).verify(code.to_s, drift_behind: DRIFT, drift_ahead: DRIFT)

          user.update!(mfa_enabled_at: Time.current)
          true
        end

        def disable!(user)
          user.update!(mfa_secret_ciphertext: nil, mfa_enabled_at: nil)
        end

        # @param after [Time, nil] reject codes from intervals at or before this
        def verify(user, code, after: nil)
          return false unless enabled?(user)
          return false if code.blank?

          !totp(user).verify(code.to_s, drift_behind: DRIFT, drift_ahead: DRIFT, after: after).nil?
        rescue StandardError
          false
        end

        def totp(user)
          ROTP::TOTP.new(decrypt(user.mfa_secret_ciphertext), issuer: "Aegis Nexus")
        end

        def encrypt(secret)
          encryptor.encrypt_and_sign(secret)
        end

        def decrypt(ciphertext)
          encryptor.decrypt_and_verify(ciphertext)
        end

        def encryptor
          key = Rails.application.key_generator.generate_key(ENCRYPTION_PURPOSE, 32)
          ActiveSupport::MessageEncryptor.new(key)
        end
      end
    end
  end
end
