# frozen_string_literal: true

module IdentityHelpers
  PASSWORD = "correct horse battery staple"

  # Identity has no published "register a user" operation yet — invitation and
  # SSO provisioning are later phases — so these specs use the context's own
  # model. That is white-box testing of Identity by Identity's suite, not a
  # boundary crossing.
  def register_user!(email: "user-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, status: "active")
    Nexus::Tenancy::Context.without_tenant_for_platform_operation do
      Nexus::Identity::Internal::Models::User.create!(
        email: email, password: password, status: status
      )
    end
  end

  def enable_mfa!(user)
    secret = Nexus::Identity::Internal::Mfa.provision!(user)
    totp = ROTP::TOTP.new(secret)
    Nexus::Identity::Internal::Mfa.enable!(user, totp.now)
    user.reload
    totp
  end

  # Log in end to end: verify credentials, then bind the human to one tenant.
  def log_in!(user, organization_id, mfa_code: nil, **options)
    Nexus::Identity::Authenticate.password(
      email: user.email, password: PASSWORD, mfa_code: mfa_code
    )
    Nexus::Identity::IssueToken.for_user(
      user_id: user.id, organization_id: organization_id, **options
    )
  end

  def register_service!(name: "svc-#{SecureRandom.hex(4)}", **options)
    Nexus::Identity::RegisterServiceIdentity.call(name: name, **options)
  end
end

RSpec.configure { |c| c.include IdentityHelpers }
