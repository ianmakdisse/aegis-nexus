# frozen_string_literal: true

module Nexus
  module Authorization
    module Internal
      # The permission catalog and the built-in role templates.
      #
      # This is data, not configuration: it is the vocabulary the whole platform
      # authorizes against, so it lives in code, is reviewed like code, and is
      # installed into the `permissions` table by PermissionCatalog.install!.
      #
      # WHY THE CATALOG IS GLOBAL AND THE ROLES ARE PER-TENANT
      #
      # A permission key is a fact about the software ("workflows.trigger exists
      # and is HIGH risk"). It is identical for every tenant and carries no
      # tenant data, so it is a platform-global row. A role is a fact about a
      # tenant's organization ("our Operators may trigger workflows"), so roles
      # and their permission attachments are tenant-scoped and RLS-protected.
      #
      # WHY ROLE TEMPLATES EXPAND AT SEED TIME
      #
      # `admin` could be stored as the single wildcard `*`, evaluated at request
      # time. It is stored as ~30 explicit rows instead. The reason is that
      # "what can an admin actually do?" must be answerable by a query rather
      # than by re-implementing the matching rules — an auditor, an incident
      # responder, and the evaluator should never disagree. The cost is that
      # adding a permission requires a backfill (see PermissionCatalog.install!),
      # which is the correct place for that decision to be visible.
      module Catalog
        # Risk tier drives policy matching and, later, approval requirements.
        #   LOW      read-only, no side effects outside the platform
        #   MEDIUM   mutates tenant state
        #   HIGH     reaches the outside world, spends money, or moves authority
        #   CRITICAL changes who may do what, or destroys data
        RISK_TIERS = %w[LOW MEDIUM HIGH CRITICAL].freeze

        # resource_type => { action => [risk_tier, description] }
        PERMISSIONS = {
          "organizations" => {
            "read"   => ["LOW",      "View organization profile and settings"],
            "update" => ["MEDIUM",   "Change organization profile and settings"],
            "delete" => ["CRITICAL", "Delete the organization and all of its data"]
          },
          "memberships" => {
            "read"   => ["LOW",      "List members of the organization"],
            "invite" => ["MEDIUM",   "Invite a person into the organization"],
            "remove" => ["HIGH",     "Remove a person from the organization"]
          },
          "teams" => {
            "read"   => ["LOW",    "List teams and their members"],
            "manage" => ["MEDIUM", "Create, rename, and dissolve teams"]
          },
          "roles" => {
            "read"   => ["LOW",      "List roles and the permissions they carry"],
            "manage" => ["CRITICAL", "Create, modify, and delete roles"]
          },
          "grants" => {
            "read"   => ["LOW",      "See who holds which role"],
            "create" => ["CRITICAL", "Give a principal a role"],
            "revoke" => ["HIGH",     "Take a role away from a principal"]
          },
          "policies" => {
            "read"   => ["LOW",      "Read the tenant's authorization policies"],
            "manage" => ["CRITICAL", "Create, modify, and delete authorization policies"]
          },
          "service_identities" => {
            "read"   => ["LOW",      "List service identities"],
            "manage" => ["CRITICAL", "Create, rotate, and revoke service credentials"]
          },
          "workflows" => {
            "read"    => ["LOW",    "View workflow definitions and runs"],
            "manage"  => ["MEDIUM", "Create and edit workflow definitions"],
            "publish" => ["HIGH",   "Publish a workflow version so new runs use it"],
            "trigger" => ["HIGH",   "Start a workflow run"],
            "cancel"  => ["HIGH",   "Cancel an in-flight workflow run"],
            "approve" => ["HIGH",   "Decide a human approval a run is waiting on"]
          },
          "agents" => {
            "read"   => ["LOW",    "View agent definitions and execution timelines"],
            "manage" => ["HIGH",   "Create and edit agents, including their tool sets"],
            "invoke" => ["HIGH",   "Run an agent"]
          },
          "tools" => {
            "read"     => ["LOW",      "List registered tools"],
            "register" => ["CRITICAL", "Register a tool an agent may call"],
            "invoke"   => ["HIGH",     "Invoke a tool directly"]
          },
          "documents" => {
            "read"   => ["LOW",    "Read documents and retrieve from knowledge"],
            "ingest" => ["MEDIUM", "Upload and ingest documents"],
            "delete" => ["HIGH",   "Delete documents and their embeddings"]
          },
          "integrations" => {
            "read"       => ["LOW",      "List integrations and connection health"],
            "connect"    => ["CRITICAL", "Establish a connection and store its credential"],
            "disconnect" => ["HIGH",     "Remove a connection"],
            "call"       => ["HIGH",     "Invoke an external system through a connector"]
          },
          "events" => {
            "read"   => ["LOW",  "Read the event log"],
            "replay" => ["HIGH", "Replay events into a projection or handler"]
          },
          "notifications" => {
            "read" => ["LOW",    "Read notification history"],
            "send" => ["MEDIUM", "Send a notification"]
          },
          "billing" => {
            "read"   => ["LOW",      "Read usage and cost"],
            "manage" => ["CRITICAL", "Set budgets and spending ceilings"]
          },
          "audit" => {
            "read"   => ["LOW",    "Read the audit timeline"],
            "verify" => ["MEDIUM", "Verify the audit chain's integrity"]
          }
        }.freeze

        # Built-in roles, defined by what they must be able to do rather than by
        # a wildcard. `owner` is the only role that holds CRITICAL permissions:
        # changing who may do what is the one authority that should never be
        # acquired by accident.
        ROLE_TEMPLATES = {
          "owner" => {
            name: "Owner",
            permissions: :all
          },
          "admin" => {
            name: "Administrator",
            # Everything operational and configurational, but not the four
            # authority-moving permissions. An admin who needs them asks an owner,
            # and that request is visible.
            permissions: { except: %w[organizations.delete roles.manage grants.create policies.manage
                                      service_identities.manage tools.register integrations.connect
                                      billing.manage] }
          },
          "operator" => {
            name: "Operator",
            # Runs the business day to day: starts work, approves it, feeds it
            # documents, and can see what happened. Changes no configuration.
            permissions: { read_all: true,
                           plus: %w[workflows.trigger workflows.cancel workflows.approve
                                    agents.invoke tools.invoke documents.ingest
                                    integrations.call notifications.send] }
          },
          "viewer" => {
            name: "Viewer",
            permissions: { read_all: true }
          }
        }.freeze

        class << self
          # [[key, resource_type, action, risk_tier, description], ...]
          def rows
            PERMISSIONS.flat_map do |resource_type, actions|
              actions.map do |action, (risk_tier, description)|
                ["#{resource_type}.#{action}", resource_type, action, risk_tier, description]
              end
            end
          end

          def keys = @keys ||= rows.map(&:first).freeze

          def key?(key) = index.key?(key.to_s)

          def risk_tier(key) = index[key.to_s]&.fetch(3)

          # key => row. Memoized: every authorization check consults it, and the
          # catalog is a frozen constant — recomputing it per request would be a
          # measurable cost on the hottest path in the system.
          def index
            @index ||= rows.to_h { |row| [row.first, row.freeze] }.freeze
          end

          # The permission keys a role template resolves to. Resolution happens
          # here, once, so that SeedSystemRoles stays a persistence concern.
          def permissions_for(role_key)
            spec = ROLE_TEMPLATES.fetch(role_key) do
              raise ArgumentError, "unknown system role #{role_key.inspect}"
            end[:permissions]

            case spec
            when :all then keys
            when Hash then resolve(spec)
            else raise ArgumentError, "unreadable permission spec for #{role_key.inspect}"
            end
          end

          private

          def resolve(spec)
            selected =
              if spec[:except]
                keys - spec.fetch(:except)
              elsif spec[:read_all]
                read_only_keys + Array(spec[:plus])
              else
                Array(spec[:plus])
              end

            unknown = selected - keys
            raise ArgumentError, "role template names permissions that are not in the catalog: #{unknown.join(', ')}" if unknown.any?

            selected.uniq.sort
          end

          # "Read" is a shape, not a name: every LOW-tier permission is read-only
          # by the definition of the tier above. Deriving the viewer role from the
          # tier keeps the two from drifting apart when a permission is added.
          def read_only_keys
            rows.select { |(_key, _rt, _action, tier, _desc)| tier == "LOW" }.map(&:first)
          end
        end
      end
    end
  end
end
