# frozen_string_literal: true

# Deliberately wrong. Each table below trips exactly one rule so the self-test
# can assert that rule fired rather than that "something" was reported.
class CreateThings < ActiveRecord::Migration[7.1]
  def change
    # OK: tenant column, tenant-leading index, RLS.
    create_table :good_table, id: :uuid do |t|
      t.uuid :organization_id, null: false
      t.timestamps
    end
    add_index :good_table, :organization_id
    enable_tenant_rls! :good_table

    # INV-13 missing-tenant-column
    create_table :no_tenant_table, id: :uuid do |t|
      t.string :name, null: false
      t.timestamps
    end

    # INV-13 missing-tenant-index
    create_table :unindexed_table, id: :uuid do |t|
      t.uuid :organization_id, null: false
      t.timestamps
    end
    enable_tenant_rls! :unindexed_table

    # INV-14 missing-rls
    create_table :unprotected_table, id: :uuid do |t|
      t.uuid :organization_id, null: false
      t.timestamps
    end
    add_index :unprotected_table, :organization_id
  end
end
