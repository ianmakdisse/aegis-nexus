# frozen_string_literal: true

# Base for every persisted model.
#
# Business models inherit TenantScopedRecord instead; this class exists for the
# handful of platform-global tables enumerated in config/ownership.yml.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
