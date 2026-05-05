module ApplicationCable
  class Connection < ActionCable::Connection::Base
    # No auth in this iteration. When auth lands, identify by current_user.
  end
end
