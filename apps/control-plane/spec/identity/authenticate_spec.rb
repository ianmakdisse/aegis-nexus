# frozen_string_literal: true

require "rails_helper"

# FR-105 — human authentication. Organized by the ways this can be wrong in a
# way that matters, not by method.
RSpec.describe Nexus::Identity::Authenticate do
  describe ".password" do
    it "verifies a correct password and returns the user, not a principal" do
      user = register_user!

      result = described_class.password(email: user.email, password: IdentityHelpers::PASSWORD)

      expect(result.user_id).to eq(user.id)
      expect(result).not_to respond_to(:membership_id)
    end

    # `users` is platform-global. Credential verification must work with no
    # tenant open, because which tenant this person is acting in has not been
    # decided yet — that is IssueToken's job.
    it "works with no tenant context at all" do
      user = register_user!

      expect(Nexus::Tenancy::Context).not_to be_present
      expect { described_class.password(email: user.email, password: IdentityHelpers::PASSWORD) }
        .not_to raise_error
    end

    it "matches the email case-insensitively" do
      user = register_user!(email: "Mixed.Case@Example.com")

      expect(described_class.password(email: "mixed.case@example.com",
                                      password: IdentityHelpers::PASSWORD).user_id).to eq(user.id)
    end

    it "rejects a wrong password" do
      user = register_user!

      expect { described_class.password(email: user.email, password: "wrong") }
        .to raise_error(described_class::Failed)
    end

    it "rejects a disabled user who knows the correct password" do
      user = register_user!(status: "disabled")

      expect { described_class.password(email: user.email, password: IdentityHelpers::PASSWORD) }
        .to raise_error(described_class::Failed)
    end

    it "rejects a user with no password set" do
      user = register_user!
      Nexus::Tenancy::Context.without_tenant_for_platform_operation do
        user.update_columns(password_digest: nil)
      end

      expect { described_class.password(email: user.email, password: IdentityHelpers::PASSWORD) }
        .to raise_error(described_class::Failed)
    end

    # The enumeration oracle. If "no such account" and "wrong password" are
    # distinguishable — by message, by class, or by anything a caller can see —
    # then a leaked email list becomes a target list.
    describe "not being an account enumeration oracle" do
      it "fails identically for an unknown address and a wrong password" do
        user = register_user!

        unknown = capture_failure { described_class.password(email: "nobody@example.com", password: "x") }
        wrong = capture_failure { described_class.password(email: user.email, password: "x") }

        expect(unknown.message).to eq(wrong.message)
        expect(unknown.class).to eq(wrong.class)
      end

      it "keeps the distinguishing detail for the audit log only" do
        user = register_user!

        unknown = capture_failure { described_class.password(email: "nobody@example.com", password: "x") }
        disabled = capture_failure do
          register_user!(email: "off@example.com", status: "disabled")
          described_class.password(email: "off@example.com", password: IdentityHelpers::PASSWORD)
        end

        expect(unknown.reason).to eq(:invalid_credentials)
        expect(disabled.reason).to eq(:inactive_user)
        expect(unknown.message).to eq(disabled.message)
        expect(user).to be_present
      end
    end

    describe "TOTP second factor" do
      it "accepts a current code" do
        user = register_user!
        totp = enable_mfa!(user)

        expect(described_class.password(email: user.email, password: IdentityHelpers::PASSWORD,
                                        mfa_code: totp.now).mfa_used).to be(true)
      end

      it "rejects a wrong code" do
        user = register_user!
        enable_mfa!(user)

        expect do
          described_class.password(email: user.email, password: IdentityHelpers::PASSWORD,
                                   mfa_code: "000000")
        end.to raise_error(described_class::Failed)
      end

      it "rejects a missing code when MFA is enabled" do
        user = register_user!
        enable_mfa!(user)

        expect { described_class.password(email: user.email, password: IdentityHelpers::PASSWORD) }
          .to raise_error(described_class::Failed)
      end

      # A TOTP code is valid for a 30-second step. Without an interval floor, a
      # code observed in transit can be replayed for the rest of that step —
      # which is the difference between MFA and the appearance of MFA.
      it "refuses to accept the same code twice" do
        user = register_user!
        totp = enable_mfa!(user)
        code = totp.now

        described_class.password(email: user.email, password: IdentityHelpers::PASSWORD, mfa_code: code)

        expect do
          described_class.password(email: user.email, password: IdentityHelpers::PASSWORD, mfa_code: code)
        end.to raise_error(described_class::Failed)
      end

      it "ignores a code when MFA is not enabled" do
        user = register_user!

        expect(described_class.password(email: user.email, password: IdentityHelpers::PASSWORD,
                                        mfa_code: "123456").mfa_used).to be(false)
      end
    end
  end

  describe ".bearer" do
    it "rejects a blank credential" do
      expect { described_class.bearer(nil) }.to raise_error(described_class::Failed)
      expect { described_class.bearer("") }.to raise_error(described_class::Failed)
    end

    it "rejects an arbitrary string" do
      expect { described_class.bearer("not-a-token") }.to raise_error(described_class::Failed)
    end
  end

  def capture_failure
    yield
    raise "expected the block to raise"
  rescue Nexus::Identity::Authenticate::Failed => e
    e
  end
end
