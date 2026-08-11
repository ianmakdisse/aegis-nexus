#!/usr/bin/env ruby
# frozen_string_literal: true

# docs-lint — documentation consistency checker for Aegis Nexus.
#
# Enforces INV-26 ("Documentation is part of the change"). Run in CI; a non-zero
# exit fails the build.
#
# Checks:
#   broken-link      A relative link points at a file that does not exist and is
#                    not declared in the planned-docs manifest.
#   broken-anchor    A link points at a heading that does not exist in the target.
#   undeclared-plan  A planned doc has been created but is still listed as planned
#                    (keeps the manifest from rotting into a permanent excuse list).
#   stale-plan       A planned doc's phase has passed but the file still does not exist.
#   missing-code     A "Related code" path does not exist in the repository.
#   orphan           A document nothing links to (excluding entry points).
#
# Usage:
#   ruby tools/docs-lint/lint.rb                 # all checks, warnings non-fatal
#   ruby tools/docs-lint/lint.rb --strict        # warnings are errors too
#   ruby tools/docs-lint/lint.rb --only=broken-link,broken-anchor
#   ruby tools/docs-lint/lint.rb --format=json

require "json"
require "set"
require "yaml"

module DocsLint
  ROOT = File.expand_path("../..", __dir__)
  DOCS = File.join(ROOT, "docs")
  MANIFEST = File.join(__dir__, "planned-docs.yml")
  CONFIG = File.join(__dir__, "config.yml")

  Finding = Struct.new(:severity, :rule, :file, :line, :message, keyword_init: true) do
    def to_s
      "#{severity.to_s.upcase.ljust(7)} #{rule.ljust(16)} #{file}:#{line}  #{message}"
    end

    def to_h
      { severity: severity, rule: rule, file: file, line: line, message: message }
    end
  end

  # A parsed markdown document: its headings (as anchor slugs) and its outbound links.
  class Document
    Link = Struct.new(:target, :anchor, :line, :raw, keyword_init: true)

    # Matches [text](target) but not image embeds; ignores autolinks and code spans.
    LINK_RE = /(?<!\!)\[(?<text>[^\]]*)\]\((?<href>[^)\s]+)(?:\s+"[^"]*")?\)/

    attr_reader :path, :rel, :anchors, :links, :code_refs

    def initialize(path)
      @path = path
      @rel = path.sub("#{ROOT}/", "")
      @anchors = Set.new
      @links = []
      @code_refs = []
      parse
    end

    # GitHub's heading-slug algorithm: strip formatting, lowercase, drop everything
    # that is not a word character, hyphen, or space, then spaces to hyphens.
    def self.slugify(heading)
      s = heading.dup
      s.gsub!(/`([^`]*)`/, '\1')                 # inline code
      s.gsub!(/\[([^\]]*)\]\([^)]*\)/, '\1')     # links -> link text
      s.gsub!(/[*_~]/, "")                       # emphasis
      s = s.strip.downcase
      s = s.gsub(/[^\p{Word}\- ]/u, "")
      s.tr(" ", "-")
    end

    private

    def parse
      in_fence = false
      section = nil

      File.readlines(@path).each_with_index do |line, idx|
        lineno = idx + 1

        if line.start_with?("```")
          in_fence = !in_fence
          next
        end
        next if in_fence

        if (m = line.match(/^(#{'#'}{1,6})\s+(.*)$/))
          heading = m[2].sub(/\s*#+\s*$/, "")
          @anchors << self.class.slugify(heading)
          section = heading.downcase
        end

        # Explicit anchors: <a id="fr-101"></a>. Stable identifiers (requirement
        # IDs, invariant IDs) are anchored explicitly so that editing a heading's
        # prose never breaks an inbound link.
        line.scan(/<a\s+(?:id|name)=["']([^"']+)["']/) { |(id)| @anchors << id.downcase }

        # "Related code" sections list repository paths in backticks.
        if section&.include?("related code")
          line.scan(/`([^`]+)`/) do |(ref)|
            next unless ref.match?(%r{\A[\w./-]+\z}) && ref.include?("/")

            @code_refs << Link.new(target: ref, anchor: nil, line: lineno, raw: ref)
          end
        end

        # Strip inline code before link extraction so examples inside backticks
        # are not treated as real links.
        scannable = line.gsub(/`[^`]*`/, "")
        scannable.scan(LINK_RE) do
          href = Regexp.last_match[:href]
          next if href.start_with?("http://", "https://", "mailto:", "#")

          target, anchor = href.split("#", 2)
          @links << Link.new(target: target, anchor: anchor, line: lineno, raw: href)
        end
      end
    end
  end

  class Linter
    ENTRY_POINTS = %w[
      docs/00-start-here/README.md
      README.md
    ].freeze

    def initialize(strict: false, only: nil)
      @strict = strict
      @only = only
      @findings = []
      @config = File.exist?(CONFIG) ? YAML.load_file(CONFIG) : {}
      @planned = load_planned
      @docs = load_docs
    end

    def run
      check_links
      check_planned_manifest
      check_code_refs
      check_orphans
      @findings
    end

    def error_count
      @findings.count { |f| f.severity == :error || (@strict && f.severity == :warning) }
    end

    private

    def enabled?(rule)
      @only.nil? || @only.include?(rule)
    end

    def add(severity, rule, file, line, message)
      return unless enabled?(rule)

      @findings << Finding.new(severity: severity, rule: rule, file: file, line: line, message: message)
    end

    def load_docs
      Dir.glob(File.join(DOCS, "**", "*.md")).sort.map { |p| Document.new(p) }
    end

    # planned-docs.yml declares documents that are intentionally referenced before
    # they exist, each with the phase that will create it. This is what lets the
    # architecture docs link forward without the linter becoming noise.
    def load_planned
      return {} unless File.exist?(MANIFEST)

      raw = YAML.load_file(MANIFEST) || {}
      (raw["planned"] || []).each_with_object({}) do |entry, acc|
        acc[entry["path"]] = entry
      end
    end

    def current_phase
      (@config["current_phase"] || 0).to_i
    end

    def resolve(from_doc, target)
      base = File.dirname(from_doc.path)
      File.expand_path(target, base)
    end

    def rel(path)
      path.sub("#{ROOT}/", "")
    end

    def check_links
      by_path = @docs.each_with_object({}) { |d, h| h[d.path] = d }

      @docs.each do |doc|
        doc.links.each do |link|
          abs = resolve(doc, link.target)
          relpath = rel(abs)

          unless File.exist?(abs)
            if @planned.key?(relpath)
              # Declared as future work — allowed, but tracked.
              next
            end

            add(:error, "broken-link", doc.rel, link.line,
                "link target does not exist: #{link.target} (resolved: #{relpath}). " \
                "Create it, fix the path, or declare it in tools/docs-lint/planned-docs.yml")
            next
          end

          next unless link.anchor
          next unless abs.end_with?(".md")

          target_doc = by_path[abs] || Document.new(abs)
          next if target_doc.anchors.include?(link.anchor)

          suggestion = closest_anchor(link.anchor, target_doc.anchors)
          hint = suggestion ? " Did you mean ##{suggestion}?" : ""
          add(:error, "broken-anchor", doc.rel, link.line,
              "anchor ##{link.anchor} not found in #{rel(abs)}.#{hint}")
        end
      end
    end

    def closest_anchor(anchor, candidates)
      candidates.min_by { |c| levenshtein(anchor, c) }.then do |best|
        best if best && levenshtein(anchor, best) <= [anchor.length / 3, 8].min
      end
    end

    def levenshtein(a, b)
      return b.length if a.empty?
      return a.length if b.empty?

      prev = (0..b.length).to_a
      a.each_char.with_index do |ca, i|
        cur = [i + 1]
        b.each_char.with_index do |cb, j|
          cur << [prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1)].min
        end
        prev = cur
      end
      prev.last
    end

    def check_planned_manifest
      @planned.each do |path, entry|
        abs = File.join(ROOT, path)
        phase = entry["phase"].to_i

        if File.exist?(abs)
          add(:warning, "undeclared-plan", "tools/docs-lint/planned-docs.yml", 0,
              "#{path} now exists — remove it from the planned manifest")
        elsif phase.positive? && phase < current_phase
          add(:error, "stale-plan", "tools/docs-lint/planned-docs.yml", 0,
              "#{path} was due in phase #{phase} (current: #{current_phase}) and still does not exist")
        end
      end
    end

    # Code paths in docs are written relative to the repository root OR relative
    # to an app root (docs about the control plane say `domains/agents/...`, not
    # `apps/control-plane/domains/agents/...`, because that is how a reader
    # working in that app thinks about it). Try both before reporting.
    def code_ref_exists?(ref)
      candidates = [File.join(ROOT, ref)]
      Dir.glob(File.join(ROOT, "apps", "*")).each { |app| candidates << File.join(app, ref) }
      candidates.any? { |c| File.exist?(c) || Dir.exist?(c) }
    end

    def check_code_refs
      @docs.each do |doc|
        doc.code_refs.each do |ref|
          next if code_ref_exists?(ref.target.sub(%r{\A/}, ""))
          next if @planned.key?(ref.target)

          add(:warning, "missing-code", doc.rel, ref.line,
              "referenced code path does not exist yet: #{ref.target}")
        end
      end
    end

    def check_orphans
      linked = Set.new
      @docs.each do |doc|
        doc.links.each { |l| linked << rel(resolve(doc, l.target)) }
      end

      @docs.each do |doc|
        next if ENTRY_POINTS.include?(doc.rel)
        next if linked.include?(doc.rel)
        next if doc.rel.end_with?("_template.md")

        add(:warning, "orphan", doc.rel, 0, "no other document links to this file")
      end
    end
  end
end

# ---------------------------------------------------------------------------

strict = ARGV.include?("--strict")
format = ARGV.find { |a| a.start_with?("--format=") }&.split("=", 2)&.last || "text"
only = ARGV.find { |a| a.start_with?("--only=") }&.split("=", 2)&.last&.split(",")

linter = DocsLint::Linter.new(strict: strict, only: only)
findings = linter.run

if format == "json"
  puts JSON.pretty_generate(findings.map(&:to_h))
else
  errors = findings.select { |f| f.severity == :error }
  warnings = findings.select { |f| f.severity == :warning }

  unless errors.empty?
    puts "\n=== ERRORS (#{errors.size}) ==="
    errors.sort_by { |f| [f.file, f.line] }.each { |f| puts f }
  end

  unless warnings.empty?
    puts "\n=== WARNINGS (#{warnings.size}) ==="
    warnings.sort_by { |f| [f.file, f.line] }.each { |f| puts f }
  end

  puts "\ndocs-lint: #{errors.size} error(s), #{warnings.size} warning(s)" \
       "#{strict ? ' [strict: warnings are fatal]' : ''}"
  puts "OK" if findings.empty?
end

exit(linter.error_count.zero? ? 0 : 1)
