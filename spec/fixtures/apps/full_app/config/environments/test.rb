Rails.application.configure do
  config.time_zone = "UTC"
  config.active_job.queue_adapter = :inline
end
