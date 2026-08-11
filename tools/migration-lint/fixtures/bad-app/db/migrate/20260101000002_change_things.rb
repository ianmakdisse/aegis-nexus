# frozen_string_literal: true

# Deliberately wrong: every operation here is unsafe under a rolling deploy.
class ChangeThings < ActiveRecord::Migration[7.1]
  def up
    # INV-11 not-null-without-default: version N still inserts without this.
    add_column :existing_table, :required_field, :string, null: false

    # INV-11 blocking-index: locks writes on an existing table.
    add_index :existing_table, :required_field

    # INV-11 destructive-ddl: no declared prior expand migration.
    remove_column :existing_table, :legacy_field
  end

  def down
    # Rollback code is destructive by definition and must NOT be reported.
    remove_column :existing_table, :required_field
    drop_table :good_table
  end
end
