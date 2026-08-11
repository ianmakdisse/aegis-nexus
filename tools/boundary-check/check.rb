#!/usr/bin/env ruby
# frozen_string_literal: true

# boundary-check — enforces the bounded-context boundaries that ADR-001 depends on.
#
# ADR-001 chose a modular monolith over microservices on one explicit assumption:
# that boundaries would be enforced mechanically rather than by discipline. This
# script is that mechanism. If it is ever downgraded from blocking to advisory,
# ADR-001's central argument no longer holds and the ADR must be revisited.
#
# Rules
#   INV-01  cross-context-table   A context references a table owned by another context.
#   INV-02  private-access        A file references another context's Internal:: namespace.
#   INV-02  undeclared-public     A context exposes a public constant not in ownership.yml.
#   INV-03  undeclared-sync       A synchronous cross-context call not listed in sync_allowed.
#   INV-04  raw-publish           Event publication outside Events::Publisher.
#   INV-13  unowned-table         A migration creates a table owned by nobody.
#
# Usage:  ruby tools/boundary-check/check.rb [--format=json] [--app=PATH]

require "json"
require "set"
require "yaml"

module BoundaryCheck
  ROOT = File.expand_path("../..", __dir__)

  Violation = Struct.new(:rule, :invariant, :file, :line, :message, keyword_init: true) do
    def to_s
      "#{invariant}  #{rule.ljust(20)} #{file}:#{line}\n         #{message}"
    end

    def to_h = to_h_struct
    def to_h_struct = { rule: rule, invariant: invariant, file: file, line: line, message: message }
  end

  class Checker
    # A context may always reach for these — they are infrastructure, not domains.
    INFRA_NAMESPACES = %w[Nexus::Tenancy Nexus::Telemetry Nexus::Cache Nexus::Jobs
                          Nexus::EventStore Nexus::Projections Nexus::Consistency].freeze

    def initialize(app_path)
      @app = app_path
      @registry = YAML.load_file(File.join(@app, "config", "ownership.yml"))
      @contexts = @registry.fetch("contexts")
      @global_tables = Set.new(@registry.fetch("platform_global", []))
      @sync_allowed = @registry.fetch("sync_allowed", [])
      @violations = []

      @table_owner = {}
      @contexts.each do |ctx, spec|
        (spec["tables"] || []).each { |t| @table_owner[t] = ctx }
      end
    end

    # Domain modules live outside app/ so they can carry the Nexus root namespace
    # (see lib/nexus.rb). Older layouts kept them under app/domains; both are
    # supported so the checker works against fixtures and any un-migrated app.
    def domains_root
      @domains_root ||= Dir.exist?(File.join(@app, "domains")) ? "domains" : File.join("app", "domains")
    end

    def run
      domain_files.each { |f| check_file(f) }
      check_public_surface
      check_migrations
      @violations
    end

    private

    def domain_files
      Dir.glob(File.join(@app, domains_root, "**", "*.rb")).sort
    end

    def context_of(path)
      m = path.match(%r{/#{Regexp.escape(domains_root)}/([^/]+)/})
      m && m[1]
    end

    def rel(path) = path.sub("#{ROOT}/", "")

    def add(rule, invariant, file, line, message)
      @violations << Violation.new(rule: rule, invariant: invariant, file: rel(file), line: line, message: message)
    end

    def check_file(path)
      ctx = context_of(path)
      return unless ctx

      in_fence = false
      File.readlines(path).each_with_index do |line, idx|
        lineno = idx + 1
        code = line.sub(/#.*\z/, "") # strip comments; boundaries are about code, not prose
        next if code.strip.empty?

        check_private_access(ctx, path, lineno, code)
        check_cross_context_tables(ctx, path, lineno, code)
        check_sync_calls(ctx, path, lineno, code)
        check_raw_publish(ctx, path, lineno, code)
        in_fence = in_fence # no-op; kept for symmetry with the docs linter
      end
    end

    # INV-02 — Internal:: is private to its own context.
    def check_private_access(ctx, path, lineno, code)
      code.scan(/Nexus::([A-Z]\w*)::Internal\b/) do |(other_const)|
        other = snake(other_const)
        next if other == ctx

        add("private-access", "INV-02", path, lineno,
            "#{ctx} reaches into #{other}'s Internal namespace. Use #{other}'s published contract " \
            "(#{(@contexts.dig(other, 'public') || []).join(', ')}) or subscribe to its events.")
      end
    end

    # INV-01 — a context may only name tables it owns.
    def check_cross_context_tables(ctx, path, lineno, code)
      # Explicit table names: self.table_name =, from(), joins("... table ..."), raw SQL.
      candidates = []
      code.scan(/table_name\s*=\s*["']([a-z_]+)["']/) { |(t)| candidates << t }
      code.scan(/\bfrom\(["']([a-z_]+)/) { |(t)| candidates << t }
      code.scan(/\b(?:JOIN|FROM|INTO|UPDATE)\s+([a-z_]{3,})\b/i) { |(t)| candidates << t.downcase }

      candidates.uniq.each do |table|
        owner = @table_owner[table]
        next if owner.nil?                 # unknown token — not a registered table
        next if owner == ctx
        next if @global_tables.include?(table)

        add("cross-context-table", "INV-01", path, lineno,
            "#{ctx} references table `#{table}`, owned by #{owner}. " \
            "Tables are private to their context — go through #{owner}'s contract or its events.")
      end
    end

    # INV-03 — synchronous cross-context calls must be declared.
    def check_sync_calls(ctx, path, lineno, code)
      code.scan(/Nexus::([A-Z]\w*)::([A-Z]\w*)/) do |(other_const, const)|
        other = snake(other_const)
        next if other == ctx
        next if const == "Internal" # handled by private-access
        next if INFRA_NAMESPACES.include?("Nexus::#{other_const}")
        next unless @contexts.key?(other)

        next if sync_permitted?(ctx, other)

        add("undeclared-sync", "INV-03", path, lineno,
            "#{ctx} calls #{other} synchronously, which is not declared in ownership.yml:sync_allowed. " \
            "Either subscribe to #{other}'s events, or add an entry with a stated reason and update the context map.")
      end
    end

    def sync_permitted?(from, to)
      @sync_allowed.any? do |rule|
        (rule["from"] == "*" || rule["from"] == from) && rule["to"] == to
      end
    end

    # INV-04 — no dual writes: only the Events context may touch a transport directly.
    def check_raw_publish(ctx, path, lineno, code)
      return if ctx == "events"

      if code.match?(/\b(Kafka|Rdkafka|Karafka)\b/) || code.match?(/\.produce\(/)
        add("raw-publish", "INV-04", path, lineno,
            "#{ctx} appears to use a broker client directly. All publication goes through " \
            "Nexus::Events::Publisher, which requires an open transaction (transactional outbox).")
      end
    end

    # INV-02 — a context's public surface is exactly what ownership.yml declares.
    def check_public_surface
      @contexts.each do |ctx, spec|
        declared = Set.new(spec["public"] || [])
        dir = File.join(@app, domains_root, ctx)
        next unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*.rb")).each do |file|
          const = camel(File.basename(file, ".rb"))
          next if declared.include?(const)

          add("undeclared-public", "INV-02", file, 1,
              "#{ctx} exposes `#{const}` at its top level but ownership.yml does not declare it public. " \
              "Move it under internal/, or declare it and document it in the context map.")
        end
      end
    end

    # INV-13 — every business table belongs to a context and carries a tenant.
    def check_migrations
      Dir.glob(File.join(@app, "db", "migrate", "*.rb")).sort.each do |file|
        File.readlines(file).each_with_index do |line, idx|
          next unless (m = line.match(/create_table\s+[:"']([a-z_]+)/))

          table = m[1]
          next if @global_tables.include?(table)
          next if @table_owner.key?(table)

          add("unowned-table", "INV-13", file, idx + 1,
              "migration creates table `#{table}` which no context owns. " \
              "Add it to the owning context in config/ownership.yml (and the context map), " \
              "or to platform_global with an ADR.")
        end
      end
    end

    def snake(const) = const.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    def camel(name) = name.split("_").map(&:capitalize).join
  end
end

app = ARGV.find { |a| a.start_with?("--app=") }&.split("=", 2)&.last ||
      File.join(BoundaryCheck::ROOT, "apps", "control-plane")
format = ARGV.find { |a| a.start_with?("--format=") }&.split("=", 2)&.last || "text"

unless File.exist?(File.join(app, "config", "ownership.yml"))
  warn "boundary-check: no ownership.yml at #{app}/config — nothing to enforce"
  exit 0
end

violations = BoundaryCheck::Checker.new(app).run

if format == "json"
  puts JSON.pretty_generate(violations.map(&:to_h_struct))
else
  if violations.empty?
    puts "boundary-check: OK — no boundary violations"
  else
    puts "\n=== BOUNDARY VIOLATIONS (#{violations.size}) ===\n\n"
    violations.sort_by { |v| [v.invariant, v.file, v.line] }.each { |v| puts v; puts }
    puts "These are constitutional violations, not style issues."
    puts "See docs/02-architecture/architecture-constitution.md and docs/02-architecture/context-map.md"
  end
end

exit(violations.empty? ? 0 : 1)
