# frozen_string_literal: true

# Isolation layer (b) of INV-14: application-level default scoping.
#
# Every business model inherits from this class. It does three things, and each
# one exists because a specific class of bug is otherwise easy to write:
#
#   1. Scopes every query to the current tenant  — stops a forgotten WHERE clause
#   2. Stamps organization_id on create          — stops an unattributed row
#   3. Refuses to run without tenant context     — stops a silent unscoped query
#
# Layer (b) is the one most likely to be bypassed accidentally (`unscoped`, a raw
# `find_by_sql`, a join built by hand), which is precisely why layers (a) — RLS —
# and (c) — the request-scoped context — exist independently of it. The isolation
# suite disables each layer in turn and asserts the other two still deny.
#
# See: ADR-009, docs/08-security/tenant-isolation.md
class TenantScopedRecord < ApplicationRecord
  self.abstract_class = true

  UnscopedQuery = Class.new(StandardError)

  # Applied to every query on every subclass.
  #
  # `default_scope` has a deserved bad reputation, but this is the case it was
  # made for: a filter that must be present on 100% of queries and whose absence
  # is a security defect rather than a missing feature.
  default_scope do
    if Nexus::Tenancy::Context.present?
      where(organization_id: Nexus::Tenancy::Context.organization_id)
    elsif Nexus::Tenancy::Context.enforced?
      # Fail closed. Returning `all` here would silently expose every tenant;
      # returning `none` would be safe but would masquerade as "no data", which
      # sends the next engineer looking for a data bug instead of a scoping bug.
      raise UnscopedQuery,
            "#{name} queried with no tenant context (INV-14 layer b). " \
            "Wrap the operation in Nexus::Tenancy::Context.with(organization_id:)."
    else
      # Enforcement disabled: ONLY the isolation suite does this, to prove that
      # layers (a) and (c) still deny on their own.
      all
    end
  end

  before_validation :assign_organization_id, on: :create
  validate :organization_matches_context

  private

  def assign_organization_id
    return if organization_id.present?
    return unless Nexus::Tenancy::Context.present?

    self.organization_id = Nexus::Tenancy::Context.organization_id
  end

  # A row whose organization_id disagrees with the active context is either a
  # bug or an attempt to write across tenants. Both should fail before the INSERT
  # reaches the database — RLS would reject it anyway, but a validation error is
  # far more debuggable than a policy violation.
  def organization_matches_context
    return unless Nexus::Tenancy::Context.present?
    return if organization_id.blank?
    return if organization_id.to_s == Nexus::Tenancy::Context.organization_id.to_s

    errors.add(
      :organization_id,
      "does not match the current tenant context " \
      "(#{organization_id} vs #{Nexus::Tenancy::Context.organization_id}). " \
      "Cross-tenant writes are never permitted."
    )
  end
end
