# frozen_string_literal: true

# Phase 3 — platform-global tables and extensions.
#
# These are the only tables permitted to exist without organization_id
# (INV-13); each is listed in config/ownership.yml under platform_global, and
# boundary-check fails the build on any create_table not accounted for there.
class CreatePlatformFoundations < ActiveRecord::Migration[7.1]
  def up
    # pgcrypto for gen_random_uuid on PostgreSQL < 13; harmless on 13+.
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")

    # Regions a tenant may be placed in (NFR-601 data residency).
    create_table :regions, id: false do |t|
      t.string :code, primary_key: true, null: false      # sa-east-1, us-east-1…
      t.string :name, null: false
      t.string :residency_zone, null: false               # BR | US | EU | APAC
      t.boolean :accepts_new_tenants, null: false, default: true
      t.timestamps
    end

    create_table :feature_flags, id: false do |t|
      t.string :key, primary_key: true, null: false
      t.boolean :enabled, null: false, default: false
      t.jsonb :conditions, null: false, default: {}
      t.timestamps
    end
  end

  def down
    drop_table :feature_flags
    drop_table :regions
  end
end
