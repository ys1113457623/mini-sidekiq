# Mixed into per-app PagesController#index. Each controller declares its
# `layout` and the action body just falls through to render the shell.
module ReactShell
  extend ActiveSupport::Concern

  def index
    # The React app handles all sub-routes; this just renders the shell HTML.
  end
end
