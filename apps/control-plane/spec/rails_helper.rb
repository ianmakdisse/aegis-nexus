# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

# Tests MUST connect as the least-privilege application role. Connecting as the
# schema owner or a superuser makes every isolation assertion meaningless —
# see docs/security/findings.md SEC-001. This default is the fix for that
# finding; overriding it is what the guard in the isolation suite catches.
ENV["DATABASE_URL"] ||= "postgres://nexus_app:nexus_app@localhost/aegis_nexus_test"

require_relative "spec_helper"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"

Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.use_transactional_fixtures = true

  # The permission catalog is platform-global vocabulary that provisioning
  # depends on, so it is installed once for the whole run — before the first
  # example's transaction opens, exactly as db/seeds.rb installs it before the
  # first tenant exists. Doing it per-example would roll it back and make every
  # provisioning test fail for a reason unrelated to what it tests.
  config.before(:suite) { Nexus::Authorization::PermissionCatalog.install! }
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Every example starts with NO tenant context. A test that needs one says so.
  # This is deliberate: it means a spec that accidentally depends on ambient
  # tenant state fails rather than passing by luck.
  config.before do
    Thread.current[Nexus::Tenancy::Context::KEY] = nil
  end
end
