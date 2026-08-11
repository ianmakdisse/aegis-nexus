# frozen_string_literal: true

# Root namespace for everything that is *not* Rails MVC.
#
# `domains/` and `infrastructure/` deliberately live outside `app/` rather than
# inside it. Two reasons:
#
#   1. Every directory under `app/` is an autoload root in Rails, which would
#      make `domains/workflows/trigger.rb` resolve to `Workflows::Trigger` and
#      leave no room for a root namespace. Pushing these directories explicitly
#      with `namespace: Nexus` gives `Nexus::Workflows::Trigger`.
#
#   2. It states the intent. `app/` is the delivery mechanism (controllers,
#      channels, serializers). `domains/` is the business. A reader should not
#      have to infer that boundary from a README.
module Nexus
end
