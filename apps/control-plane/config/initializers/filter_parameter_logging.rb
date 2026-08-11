# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # INV-18. Added with the authentication flows (ADR-011): `otp` does not match
  # `mfa_code`, and a second factor in a log is a second factor an attacker has.
  # `digest` is here because a stored digest is not a secret but is still a
  # cracking target that has no business in a log line.
  :mfa, :digest, :credential
]
