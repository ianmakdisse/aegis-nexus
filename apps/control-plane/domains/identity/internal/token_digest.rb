# frozen_string_literal: true

require "securerandom"
require "digest"

module Nexus
  module Identity
    module Internal
      # Generation, storage form, and comparison of bearer secrets.
      #
      # Three rules, all of which exist because the obvious implementation gets
      # each one wrong:
      #
      #   1. The plaintext secret is returned exactly once, at creation, and is
      #      never stored. A database read must not yield a usable credential.
      #   2. Comparison is constant-time. A `==` on a digest leaks, through
      #      timing, how many leading bytes an attacker guessed correctly — which
      #      turns a 2^256 search into a byte-at-a-time one.
      #   3. Digests are SHA-256, not bcrypt. These are high-entropy random
      #      values, not passwords: there is no dictionary to defend against, and
      #      a deliberately slow hash on the token path would put ~100 ms of
      #      key stretching in front of every service call for no security gain.
      #      Passwords use bcrypt precisely because they are the opposite case.
      module TokenDigest
        # 256 bits. urlsafe_base64 so a token survives a header, a query string,
        # and a copy-paste without encoding surprises.
        BYTES = 32

        module_function

        def generate = SecureRandom.urlsafe_base64(BYTES)

        def digest(token) = Digest::SHA256.hexdigest(token.to_s)

        # Compare a presented secret against a stored digest without leaking
        # position information through timing.
        def matches?(presented, stored_digest)
          return false if presented.blank? || stored_digest.blank?

          ActiveSupport::SecurityUtils.secure_compare(digest(presented), stored_digest)
        end
      end
    end
  end
end
