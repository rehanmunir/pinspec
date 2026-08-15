# frozen_string_literal: true

# Several public methods, none conventional. Nothing here says which one a reader
# means, so pinspec must ask rather than pick.
class AuditLog
  def flush
    :flushed
  end

  def rotate
    :rotated
  end

  def archive
    :archived
  end
end
