Rails.application.config.after_initialize do
  next if Rails.env.test?
  RefreshRateJob.perform_later
end