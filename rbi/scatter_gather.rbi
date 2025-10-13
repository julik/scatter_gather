# typed: strong
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
  DEFAULT_GATHER_CONFIG = T.let({
  max_attempts: 10,
  poll_interval: 2
}.freeze, T.untyped)
  VERSION = T.let("0.1.2", T.untyped)

  # sord omit - no YARD return type given, using untyped
  # Updates the completions table with the status of this job
  sig { returns(T.untyped) }
  def register_completion_for_gathering; end

  # ActiveJob itself does not maintain a "one record per job" database entry where we could reliably track job completion.
  # The underlying job storage (e.g., Sidekiq, Que, DelayedJob) is determined by the ActiveJob adapter, and their implementation details vary.
  # As a result, to enable reliable scatter-gather orchestration, we create our own completion tracking records.
  # Each job that is meant to be gathered later inserts a record into the scatter_gather_completions table when it is enqueued,
  # and marks it as completed upon finishing. This ensures adapter-independent, uniform dependency tracking.
  class Completion < ActiveRecord::Base
    # sord warn - DependencyStatus wasn't able to be resolved to a constant in this project
    # Collect status information for the given active job IDs
    # 
    # _@param_ `active_job_ids` — Array of ActiveJob IDs to check
    # 
    # _@return_ — Array of DependencyStatus objects
    sig { params(active_job_ids: T::Array[String]).returns(T::Array[DependencyStatus]) }
    def self.collect_statuses(active_job_ids); end

    # sord warn - DependencyStatus wasn't able to be resolved to a constant in this project
    # Check if all dependencies are completed
    # 
    # _@param_ `dependency_statuses` — Array of dependency statuses
    # 
    # _@return_ — true if all dependencies are completed
    sig { params(dependency_statuses: T::Array[DependencyStatus]).returns(T::Boolean) }
    def self.all_dependencies_completed?(dependency_statuses); end
  end

  # Internal job class for polling and coordinating gather operations
  class GatherJob < ActiveJob::Base
    include ScatterGather

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def logger; end

    # sord omit - no YARD type given for "wait_for_active_job_ids:", using untyped
    # sord omit - no YARD type given for "target_job:", using untyped
    # sord omit - no YARD type given for "gather_config:", using untyped
    # sord omit - no YARD type given for "remaining_attempts:", using untyped
    # sord omit - no YARD return type given, using untyped
    sig do
      params(
        wait_for_active_job_ids: T.untyped,
        target_job: T.untyped,
        gather_config: T.untyped,
        remaining_attempts: T.untyped
      ).returns(T.untyped)
    end
    def perform(wait_for_active_job_ids:, target_job:, gather_config:, remaining_attempts:); end

    # sord omit - no YARD type given for "dependency_statuses", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(dependency_statuses: T.untyped).returns(T.untyped) }
    def tally_in_logger_format(dependency_statuses); end

    # sord omit - no YARD type given for "target_job", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(target_job: T.untyped).returns(T.untyped) }
    def perform_target_later_from_args(target_job); end

    # sord omit - no YARD return type given, using untyped
    # Updates the completions table with the status of this job
    sig { returns(T.untyped) }
    def register_completion_for_gathering; end
  end

  # Proxy class that mimics ActiveJob behavior for gather jobs
  class GatherJobProxy
    # sord omit - no YARD type given for "target_class", using untyped
    # sord omit - no YARD type given for "ids", using untyped
    # sord omit - no YARD type given for "config", using untyped
    sig { params(target_class: T.untyped, ids: T.untyped, config: T.untyped).void }
    def initialize(target_class, ids, config); end

    # Mimic ActiveJob's perform_later method
    # 
    # _@param_ `args` — Positional arguments to pass to the target job's perform method
    # 
    # _@param_ `kwargs` — Keyword arguments to pass to the target job's perform method
    # 
    # _@return_ — Enqueues the gather job
    sig { params(args: T::Array[T.untyped], kwargs: T::Hash[T.untyped, T.untyped]).void }
    def perform_later(*args, **kwargs); end
  end

  # Custom exception for when gather job exhausts attempts
  class DependencyTimeoutError < StandardError
    # sord omit - no YARD type given for "max_attempts", using untyped
    # sord omit - no YARD type given for "dependency_statuses", using untyped
    sig { params(max_attempts: T.untyped, dependency_statuses: T.untyped).void }
    def initialize(max_attempts, dependency_statuses); end

    # sord warn - DependencyStatus wasn't able to be resolved to a constant in this project
    # Format dependency statuses as a plaintext table
    # 
    # _@param_ `dependency_statuses` — Array of dependency statuses
    # 
    # _@return_ — Formatted table string
    sig { params(dependency_statuses: T::Array[DependencyStatus]).returns(String) }
    def format_dependency_table(dependency_statuses); end

    # sord omit - no YARD type given for :dependency_statuses, using untyped
    # Returns the value of attribute dependency_statuses.
    sig { returns(T.untyped) }
    attr_reader :dependency_statuses

    # sord omit - no YARD type given for :max_attempts, using untyped
    # Returns the value of attribute max_attempts.
    sig { returns(T.untyped) }
    attr_reader :max_attempts
  end

  module Generators
    # The generator is used to install ScatterGather. It adds the migration that creates
    # the scatter_gather_completions table.
    # Run it with `bin/rails g scatter_gather:install` in your console.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      # sord omit - no YARD return type given, using untyped
      # Generates migration file that creates the scatter_gather_completions table.
      sig { returns(T.untyped) }
      def create_migration_file; end

      # sord omit - no YARD return type given, using untyped
      sig { returns(T.untyped) }
      def migration_version; end
    end
  end
end
