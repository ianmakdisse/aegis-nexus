#!/usr/bin/env ruby
# frozen_string_literal: true

# migration-lint — enforces that a schema change is safe to deploy and safe to
# be a tenant on.
#
# WHY THIS EXISTS
#
# INV-11 says version N and N+1 of the application must both run correctly
# against the intermediate schema, because rolling deploys run two code versions
# simultaneously *by design*. That invariant was enforced by review and by the
# N/N+1 CI job, which only catches a dropped column if some test happens to
# exercise it. TD-005 recorded that gap as P1, due in the phase where the first
# real domain migrations land. This is that tool.
#
# It also enforces the two schema facts that make tenant isolation true at all
# (INV-13, INV-14). boundary-check already rejects a table no context owns; it
# cannot see whether that table carries a tenant, is indexed by one, or has a
# row-level security policy. Those are the failures that are silent until they
# are a breach.
#
# Rules
#   INV-11  destructive-ddl          drop/rename/remove without a declared prior expand
#   INV-11  not-null-without-default a new NOT NULL column the running version cannot populate
#   INV-11  blocking-index           add_index on an existing table without CONCURRENTLY
#   INV-13  missing-tenant-column    a business table with no organization_id
#   INV-13  missing-tenant-index     a tenant table not indexed by organization_id first
#   INV-14  missing-rls              a tenant table with no row-level security policy
#
# LIMITS — read these before trusting a green run.
#
# This is a text matcher, not a parser (the same trade boundary-check makes, for
# the same reason). It cannot see DDL built by string interpolation, executed
# through `execute` with a computed name, or generated in a loop over a variable.
# `execute` blocks are checked for destructive keywords but not understood. A
# determined migration can defeat it. It catches the realistic mistake, which is
# somebody writing an ordinary destructive migration without realizing that a
# rolling deploy makes it an outage.
#
# Usage:  ruby tools/migration-lint/lint.rb [--format=json] [--app=PATH]

require "json"
require "set"
require "yaml"

module MigrationLint
  ROOT = File.expand_path("../..", __dir__)

  Violation = Struct.new(:rule, :invariant, :file, :line, :message, keyword_init: true) do
    def to_s
      "#{invariant}  #{rule.ljust(24)} #{file}:#{line}\n         #{message}"
    end

    def to_h_struct = { rule: rule, invariant: invariant, file: file, line: line, message: message }
  end

  # One migration file, reduced to the facts the rules care about.
  Parsed = Struct.new(:path, :version, :created_tables, :indexes, :added_columns,
                      :destructive, :rls_tables, :expands_on, keyword_init: true)

  CreatedTable = Struct.new(:name, :line, :tenant_column, :id_type, keyword_init: true)
  AddedIndex = Struct.new(:table, :columns, :line, :concurrent, keyword_init: true)
  AddedColumn = Struct.new(:table, :name, :line, :null_false, :has_default, keyword_init: true)
  Destructive = Struct.new(:operation, :line, :text, keyword_init: true)

  class Linter
    # A migration may declare that it is the *contract* half of an
    # expand→migrate→contract sequence by naming the migration that expanded:
    #
    #   # expand-migration: 20260810000004
    #
    # The named migration must exist and must be older. This is deliberately a
    # human assertion rather than something inferred: the linter cannot know
    # whether the intervening deploy actually happened, and pretending it could
    # would be worse than asking.
    EXPAND_DIRECTIVE = /^\s*#\s*expand-migration:\s*(\d+)/

    DESTRUCTIVE_OPS = {
      "drop_table" => "drops a table",
      "remove_column" => "removes a column",
      "rename_column" => "renames a column",
      "rename_table" => "renames a table",
      "remove_index" => "removes an index",
      "change_column_null" => "tightens a column's nullability"
    }.freeze

    DESTRUCTIVE_SQL = /\b(DROP\s+TABLE|DROP\s+COLUMN|ALTER\s+TABLE\s+\S+\s+RENAME)\b/i

    def initialize(app_path)
      @app = app_path
      registry_path = File.join(@app, "config", "ownership.yml")
      registry = File.exist?(registry_path) ? YAML.load_file(registry_path) : {}
      # INV-13 exemptions. `platform_global` is included because a table with no
      # owner necessarily has no tenant either; `tenant_exempt` is the
      # authoritative list and carries the justification for each entry.
      @tenant_exempt = Set.new(registry.fetch("platform_global", []) + registry.fetch("tenant_exempt", []))
      @violations = []
    end

    def run
      migrations = migration_files.map { |f| parse(f) }

      # Cross-file facts: RLS may be declared in a later migration than the one
      # that created the table (Phase 3 enables it in bulk), and a contract
      # migration references an earlier one by version.
      rls_tables = migrations.flat_map(&:rls_tables).to_set
      versions = migrations.map(&:version).to_set

      migrations.each do |migration|
        check_tenant_conformance(migration, rls_tables)
        check_rolling_safety(migration)
        check_destructive(migration, versions)
      end

      @violations
    end

    private

    def migration_files = Dir.glob(File.join(@app, "db", "migrate", "*.rb")).sort

    def rel(path) = path.sub("#{ROOT}/", "")

    def add(rule, invariant, file, line, message)
      @violations << Violation.new(rule: rule, invariant: invariant, file: rel(file), line: line, message: message)
    end

    # ---- parsing ----------------------------------------------------------

    def parse(path)
      parsed = Parsed.new(path: path, version: File.basename(path)[/\A\d+/],
                          created_tables: [], indexes: [], added_columns: [],
                          destructive: [], rls_tables: [], expands_on: nil)
      open_table = nil
      # `def down` is the rollback. Its whole job is to undo, so it is
      # destructive by definition and linting it would make every reversible
      # migration unlintable — which is how a tool teaches people to disable it.
      in_down = nil

      # The bulk RLS form is a multi-line array constant, so it is matched
      # against the whole file rather than line by line.
      content = File.read(path)
      content.scan(/TENANT_TABLES\s*=\s*%w\[([^\]]*)\]/m) { |(list)| parsed.rls_tables.concat(list.split) }

      File.readlines(path).each_with_index do |raw, idx|
        lineno = idx + 1
        parsed.expands_on ||= raw[EXPAND_DIRECTIVE, 1]

        code = raw.sub(/#.*\z/, "")
        next if code.strip.empty?

        if in_down
          in_down = nil if code.match?(/^\s{0,#{in_down}}end\b/)
          next
        end

        if (m = code.match(/^(\s*)def\s+(?:self\.)?down\b/))
          in_down = m[1].length
          next
        end

        # Inside a create_table block, `t.uuid :organization_id` is what makes
        # the table a tenant table. The block ends at the first `end` indented
        # no deeper than the create_table line itself.
        if open_table
          open_table[:table].tenant_column = true if code.match?(/\bt\.uuid\s+:organization_id\b/)
          open_table = nil if code.match?(/^\s{0,#{open_table[:indent]}}end\b/)
          next
        end

        if (m = code.match(/^(\s*)create_table\s+[:"']([a-z_]+)["']?(.*)$/))
          table = CreatedTable.new(name: m[2], line: lineno, tenant_column: false,
                                   id_type: m[3][/id:\s*:(\w+)/, 1])
          parsed.created_tables << table
          # A single-line create_table (no block) has no columns to scan.
          open_table = { table: table, indent: m[1].length } if code.include?("do |")
          next
        end

        if (m = code.match(/^\s*add_index\s+[:"']([a-z_]+)["']?\s*,\s*(.+)$/))
          parsed.indexes << AddedIndex.new(table: m[1], columns: index_columns(m[2]), line: lineno,
                                           concurrent: code.include?("algorithm: :concurrently"))
          next
        end

        if (m = code.match(/^\s*add_column\s+[:"']([a-z_]+)["']?\s*,\s*[:"']([a-z_]+)["']?(.*)$/))
          parsed.added_columns << AddedColumn.new(table: m[1], name: m[2], line: lineno,
                                                  null_false: m[3].include?("null: false"),
                                                  has_default: m[3].include?("default:"))
          next
        end

        DESTRUCTIVE_OPS.each_key do |op|
          parsed.destructive << Destructive.new(operation: op, line: lineno, text: code.strip) if code.match?(/^\s*#{op}\b/)
        end
        parsed.destructive << Destructive.new(operation: "raw SQL", line: lineno, text: code.strip) if code.match?(DESTRUCTIVE_SQL)

        parsed.rls_tables.concat(rls_declarations(code))
      end

      parsed
    end

    # `add_index :t, %i[a b]` and `add_index :t, :a` both reduce to a column
    # list; only the leading column matters to the tenant-index rule.
    def index_columns(rest)
      list = rest[/%i\[([a-z_\s]+)\]/, 1]
      return list.split if list

      [rest[/[:"']([a-z_]+)/, 1]].compact
    end

    # Two accepted ways to put a table under row-level security:
    #
    #   enable_tenant_rls! :workflow_runs        the helper (preferred)
    #   TENANT_TABLES = %w[a b c]                the Phase 3 bulk form
    #
    # Both are recognized so that the tool did not require rewriting a migration
    # that has already been applied — editing an applied migration to satisfy a
    # linter is a worse habit than the one being enforced.
    def rls_declarations(code)
      m = code.match(/enable_tenant_rls!\s*[(\s]\s*[:"']([a-z_]+)/)
      m ? [m[1]] : []
    end

    # ---- rules ------------------------------------------------------------

    def check_tenant_conformance(migration, rls_tables)
      migration.created_tables.each do |table|
        next if @tenant_exempt.include?(table.name)

        unless table.tenant_column
          add("missing-tenant-column", "INV-13", migration.path, table.line,
              "`#{table.name}` has no `organization_id`. Every business row is attributable to exactly " \
              "one tenant; if this table genuinely has no tenant, add it to ownership.yml:tenant_exempt " \
              "with an ADR and a stated reason.")
          next
        end

        unless indexed_by_tenant?(table.name, migration, rls_tables)
          add("missing-tenant-index", "INV-13", migration.path, table.line,
              "`#{table.name}.organization_id` is not the leading column of any index. Every query on this " \
              "table filters by tenant — via RLS if not explicitly — so without this index every tenant pays " \
              "for a scan over every other tenant's rows.")
        end

        next if rls_tables.include?(table.name)

        add("missing-rls", "INV-14", migration.path, table.line,
            "`#{table.name}` has no row-level security policy. Isolation layer (a) is the one that keeps " \
            "working when the application has a bug — call `enable_tenant_rls! :#{table.name}` in this " \
            "migration.")
      end
    end

    def indexed_by_tenant?(table_name, migration, _rls)
      migration.indexes.any? { |i| i.table == table_name && i.columns.first == "organization_id" }
    end

    def check_rolling_safety(migration)
      created_here = migration.created_tables.map(&:name).to_set

      migration.added_columns.each do |column|
        next if created_here.include?(column.table)
        next unless column.null_false
        next if column.has_default

        add("not-null-without-default", "INV-11", migration.path, column.line,
            "`#{column.table}.#{column.name}` is NOT NULL with no default. During a rolling deploy the " \
            "previous version is still inserting rows without this column, and every one of those inserts " \
            "fails. Add a default, or expand → backfill → contract across separate deploys.")
      end

      migration.indexes.each do |index|
        next if created_here.include?(index.table)
        next if index.concurrent

        add("blocking-index", "INV-11", migration.path, index.line,
            "`add_index` on the existing table `#{index.table}` without `algorithm: :concurrently` takes a " \
            "lock that blocks writes for the duration of the build. Use `disable_ddl_transaction!` and " \
            "`algorithm: :concurrently`.")
      end
    end

    def check_destructive(migration, versions)
      return if migration.destructive.empty?

      declared = migration.expands_on

      migration.destructive.each do |op|
        if declared.nil?
          add("destructive-ddl", "INV-11", migration.path, op.line,
              "this migration #{DESTRUCTIVE_OPS.fetch(op.operation, 'changes the schema destructively')}, " \
              "and version N of the application is still running against it during the deploy. If the expand " \
              "and backfill already shipped in an earlier deploy, say so with a " \
              "`# expand-migration: <version>` comment naming it.")
        elsif !versions.include?(declared)
          add("destructive-ddl", "INV-11", migration.path, op.line,
              "declares `expand-migration: #{declared}`, but no migration with that version exists.")
        elsif declared >= migration.version
          add("destructive-ddl", "INV-11", migration.path, op.line,
              "declares `expand-migration: #{declared}`, which is not older than this migration " \
              "(#{migration.version}). The expand must have shipped in an earlier deploy, not this one.")
        end
      end
    end
  end
end

app = ARGV.find { |a| a.start_with?("--app=") }&.split("=", 2)&.last ||
      File.join(MigrationLint::ROOT, "apps", "control-plane")
format = ARGV.find { |a| a.start_with?("--format=") }&.split("=", 2)&.last || "text"

unless Dir.exist?(File.join(app, "db", "migrate"))
  warn "migration-lint: no db/migrate at #{app} — nothing to check"
  exit 0
end

violations = MigrationLint::Linter.new(app).run

if format == "json"
  puts JSON.pretty_generate(violations.map(&:to_h_struct))
elsif violations.empty?
  puts "migration-lint: OK — no unsafe schema changes"
else
  puts "\n=== MIGRATION VIOLATIONS (#{violations.size}) ===\n\n"
  violations.sort_by { |v| [v.file, v.line] }.each { |v| puts v; puts }
  puts "A rolling deploy runs two versions of the application at once. See INV-11 and"
  puts "docs/02-architecture/architecture-constitution.md"
end

exit(violations.empty? ? 0 : 1)
