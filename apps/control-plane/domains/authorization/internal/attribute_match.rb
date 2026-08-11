# frozen_string_literal: true

module Nexus
  module Authorization
    module Internal
      # Attribute matching, shared by grant conditions and policy matchers.
      #
      # Both answer the same question — "do the request's attributes satisfy this
      # set of expectations?" — and they must answer it identically. Two
      # implementations of one rule is how a condition ends up meaning something
      # subtly different depending on which table it was stored in.
      module AttributeMatch
        module_function

        # `expected` is {name => value | [values]}; every named attribute must be
        # present in `actual` and match one of the accepted values.
        #
        # A missing attribute never satisfies a condition. Silence is not consent:
        # a grant conditioned on `environment = staging` must not be usable by a
        # caller that simply omitted `environment`.
        def satisfied?(expected, actual)
          return true if expected.nil? || (expected.respond_to?(:empty?) && expected.empty?)
          return false unless expected.is_a?(Hash)

          actual ||= {}

          expected.all? do |name, accepted|
            value = actual[name.to_s] || actual[name.to_sym]
            !value.nil? && Array(accepted).map(&:to_s).include?(value.to_s)
          end
        end
      end
    end
  end
end
