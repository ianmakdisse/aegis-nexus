# frozen_string_literal: true

# Seeds must be idempotent and safe to run in every environment, including
# production on every deploy. Nothing here creates tenant data.

# The permission catalog is platform-global vocabulary, not tenant data, and
# tenant provisioning depends on it: SeedSystemRoles refuses to run against an
# empty catalog rather than issue four roles that grant nothing.
installed = Nexus::Authorization::PermissionCatalog.install!
puts "permission catalog: #{installed} permissions installed"
