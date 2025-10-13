# frozen_string_literal: true

require "active_support"
require "active_record"
require "active_job"
require "json"
require_relative "scatter_gather/version"

# Scatter-Gather Pattern for ActiveJob
#
# This module provides a scatter-gather pattern for coordinating job execution.
# Jobs can wait for other jobs to complete before executing, with configurable
# polling, retry, and timeout behavior.
#
# Example workflow:
#   # Start some scatter jobs
#   email_parser_job = EmailParserJob.perform_later(email_id: 123)
#   attachment_processor_job = AttachmentProcessorJob.perform_later(email_id: 123)
#   ai_categorizer_job = AICategorizerJob.perform_later(email_id: 123)
#
#   # Create a gather job that waits for all dependencies to complete
#   NotifyCompleteJob.gather(email_parser_job, attachment_processor_job, ai_categorizer_job).perform_later
#
# The gather job will:
# - Check if all dependencies are complete
# - If complete: enqueue the target job immediately
# - If not complete: poll every 2 seconds (configurable), re-enqueuing itself
# - After 10 attempts (configurable): discard with error reporting
#
# Configuration options:
#   - max_attempts: Number of polling attempts before giving up (default: 10)
#   - poll_interval: Time between polling attempts (default: 2.seconds)
#
# Example with custom configuration:
#   TouchingJob.gather(jobs, poll_interval: 0.2.seconds, max_attempts: 4).perform_later(final_path)
module ScatterGather
  extend ActiveSupport::Concern

  # Autoload sub-modules
  autoload :DependencyStatus, "scatter_gather/dependency_status"
  autoload :Completion, "scatter_gather/completion"
  autoload :GatherJobProxy, "scatter_gather/gather_job_proxy"
  autoload :DependencyTimeoutError, "scatter_gather/dependency_timeout_error"
  autoload :GatherJob, "scatter_gather/gather_job"

  # Default configuration for gather jobs
  DEFAULT_GATHER_CONFIG = {
    max_attempts: 10,
    poll_interval: 2
  }.freeze

  included do
    after_perform :register_completion_for_gathering
    discard_on ScatterGather::DependencyTimeoutError

    def self.gather(*active_jobs, **gather_config_options)
      active_jobs = Array(active_jobs).flatten
      config = DEFAULT_GATHER_CONFIG.merge(gather_config_options)

      # Pre-insert IDs to wait for
      t = Time.current
      attrs = active_jobs.map do |aj|
        {
          active_job_id: aj.job_id,
          active_job_class_name: aj.class.name,
          status: "pending",
          created_at: t,
          updated_at: t
        }
      end
      ScatterGather::Completion.insert_all(attrs, returning: false)
      ScatterGather::Completion.where("created_at < ?", 1.week.ago).delete_all

      # Return a proxy object that behaves like an ActiveJob proxy
      GatherJobProxy.new(self, active_jobs.map(&:job_id), config)
    end
  end

  # Updates the completions table with the status of this job
  def register_completion_for_gathering
    n_updated = ScatterGather::Completion.where(active_job_id: job_id).update_all(status: "completed", updated_at: Time.current)
    if n_updated > 0
      logger.tagged("ScatterGather").info { "Registered completion of #{self.class.name} id=#{job_id} since it will be gathered" }
    end
  end
end
