# frozen_string_literal: true

# Phase 5 — how platform processes find their work (ADR-013).
#
# `organizations` is RLS-protected and no application role bypasses policy, so a
# correctly isolated system cannot list its own tenants. Every per-tenant
# background process — relay, consumer, projector, scheduler, reconciliation —
# is blocked on that, not just the two Phase 5 built.
#
# This table holds the set of tenant IDENTIFIERS, and deliberately nothing else.
# It locates a tenant; it does not describe one. A name, a slug, a setting or a
# count would turn an enumeration surface into a disclosure surface, and adding
# one requires a new ADR.
class CreateTenantDirectory < ActiveRecord::Migration[7.1]
  def change
    # No RLS, and no organization_id: this is platform topology, the same shape
    # as `regions` and `feature_flags`. Declared in ownership.yml:tenant_exempt.
    create_table :tenant_directory, id: false do |t|
      t.uuid :organization_id, primary_key: true, null: false
      t.string :status, null: false, default: "active"   # active | suspended | closed
      t.string :region_code, null: false
      t.string :tier, null: false, default: "pool"       # pool | dedicated (ADR-009)
      t.timestamps
    end

    # The relay's enumeration query: active tenants, in a stable order so a
    # sharded loop can split the range deterministically (Phase 15).
    add_index :tenant_directory, %i[status region_code], name: "index_tenant_directory_active"
  end
end
