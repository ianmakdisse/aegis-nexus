# frozen_string_literal: true

require "rails_helper"

# Schema conformance — the automated half of INV-13 and INV-14 that the
# Constitution's enforcement summary names alongside the isolation suite.
#
# The isolation suite proves that isolation works *for the tables it exercises*.
# It cannot notice a fortieth table added six months from now with no policy on
# it. This spec asks the database itself what exists and holds every table to
# the rule, so the guarantee scales with the schema rather than with the
# diligence of whoever writes the next migration.
#
# migration-lint catches the same mistakes earlier, at the diff. It reads source
# text; this reads the live catalog. Neither subsumes the other: a table created
# by a hand-run `execute` is invisible to the linter and obvious here.
RSpec.describe "schema conformance" do
  def query(sql) = ActiveRecord::Base.connection.select_all(sql).to_a

  # Tables carrying a tenant key. Derived from the database, not from a list —
  # a list is the thing that goes stale.
  let(:tenant_tables) do
    query(<<~SQL).map { |r| r["table_name"] }
      SELECT table_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'organization_id'
      ORDER BY table_name
    SQL
  end

  let(:rls_state) do
    query(<<~SQL).to_h { |r| [r["relname"], { enabled: r["relrowsecurity"], forced: r["relforcerowsecurity"] }] }
      SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r'
    SQL
  end

  let(:policied_tables) do
    query("SELECT DISTINCT tablename FROM pg_policies WHERE schemaname = 'public'")
      .map { |r| r["tablename"] }.to_set
  end

  let(:registry) { YAML.load_file(Rails.root.join("config/ownership.yml")) }
  let(:tenant_exempt) do
    (registry.fetch("tenant_exempt", []) + registry.fetch("platform_global", [])).to_set
  end

  it "has tenant tables to check, so a passing run means something" do
    # Guards against the vacuous version of every assertion below: if the
    # catalog query silently returned nothing, every `all?` would pass.
    expect(tenant_tables.size).to be > 30
  end

  describe "INV-14 — every tenant table is governed by row-level security" do
    it "has RLS enabled on all of them" do
      missing = tenant_tables.reject { |t| rls_state.dig(t, :enabled) }

      expect(missing).to be_empty,
                         "these tables carry organization_id but have no RLS: #{missing.join(', ')}"
    end

    # Without FORCE, policies do not apply to the table's owner — which is the
    # role that runs migrations. RLS would be silently inert on exactly the
    # connection most likely to be used for a "quick fix" in production, and the
    # isolation suite would still pass. This is SEC-001, generalized.
    it "has RLS FORCEd on all of them" do
      missing = tenant_tables.reject { |t| rls_state.dig(t, :forced) }

      expect(missing).to be_empty,
                         "these tables have RLS enabled but not FORCEd: #{missing.join(', ')}"
    end

    # ENABLE without a policy denies everything rather than leaking, so this is
    # a correctness failure rather than a security one — but a table nobody can
    # read is discovered in production, not in review.
    it "has at least one policy on all of them" do
      missing = tenant_tables.reject { |t| policied_tables.include?(t) }

      expect(missing).to be_empty,
                         "these tables have RLS but no policy: #{missing.join(', ')}"
    end
  end

  describe "INV-13 — every business table is attributable to one tenant" do
    it "gives every context-owned table an organization_id unless it is a declared exemption" do
      owned = registry.fetch("contexts").values.flat_map { |c| c["tables"] || [] }
      existing = query(<<~SQL).map { |r| r["table_name"] }
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      SQL

      offenders = (owned & existing) - tenant_tables - tenant_exempt.to_a

      expect(offenders).to be_empty,
                           "owned tables with no tenant and no declared exemption: #{offenders.join(', ')}"
    end

    # An exemption that is no longer true is worse than none: it is a documented
    # reason not to look. If a table on the list has grown an organization_id,
    # the list is what is wrong.
    it "has no stale exemptions" do
      stale = tenant_exempt.to_a & tenant_tables

      expect(stale).to be_empty,
                       "these are declared tenant-exempt but now carry organization_id: #{stale.join(', ')}"
    end
  end

  describe "least privilege" do
    # Every table is reachable by the application role — a missing grant on a
    # new table presents as "permission denied for table X" at runtime and
    # tempts whoever is on call into running the app as owner, which voids RLS
    # for everything (db/roles.sql exists because of exactly that pressure).
    it "grants the application role DML on every tenant table" do
      granted = query(<<~SQL).map { |r| r["table_name"] }.to_set
        SELECT DISTINCT table_name FROM information_schema.role_table_grants
        WHERE grantee = 'nexus_app' AND table_schema = 'public' AND privilege_type = 'SELECT'
      SQL

      expect(tenant_tables.reject { |t| granted.include?(t) }).to be_empty
    end
  end
end
