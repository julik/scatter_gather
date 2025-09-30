# frozen_string_literal: true

require "active_support"
require "active_record"
require "active_job"
require "json"

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

  class Completion < ActiveRecord::Base
    self.table_name = "scatter_gather_completions"

    def self.collect_statuses(active_job_ids)
      statuses = active_job_ids.map { |it| [it, :unknown] }.to_h
      statuses_from_completions = where(active_job_id: active_job_ids)
        .pluck(:active_job_id, :status)
        .map do |(id, st)|
          [id, st.to_sym]
        end.to_h
      statuses.merge!(statuses_from_completions)
    end
  end

  # Default configuration for gather jobs
  DEFAULT_GATHER_CONFIG = {
    max_attempts: 10,
    poll_interval: 2.seconds
  }.freeze

  # Proxy class that mimics ActiveJob behavior for gather jobs
  class GatherJobProxy
    def initialize(target_class, ids, config)
      @target_class = target_class
      @ids = ids
      @config = config.with_indifferent_access
    end

    # Mimic ActiveJob's perform_later method
    # @param args [Array] Positional arguments to pass to the target job's perform method
    # @param kwargs [Hash] Keyword arguments to pass to the target job's perform method
    # @return [void] Enqueues the gather job
    def perform_later(*args, **kwargs)
      job_arguments = {cn: @target_class.name, p: args, k: kwargs}
      gather_job_params = {
        wait_for_active_job_ids: @ids,
        target_job: job_arguments,
        gather_config: @config,
        remaining_attempts: @config.fetch(:max_attempts) - 1
      }
      tagged = ActiveSupport::TaggedLogging.new(Rails.logger).tagged("ScatterGather")
      tagged.info { "Enqueueing gather job waiting for #{@ids.inspect} to run a #{@target_class.name} after" }
      GatherJob.perform_later(**gather_job_params)
    end
  end

  # Custom exception for when gather job exhausts attempts
  class DependencyTimeoutError < StandardError
    attr_reader :dependency_status

    def initialize(max_attempts, dependency_status)
      @dependency_status = dependency_status
      super(<<~MSG)
        Gather failed after #{max_attempts} attempts. Dependencies:
        
        #{JSON.pretty_generate(dependency_status)}
      MSG
    end
  end

  # Internal job class for polling and coordinating gather operations
  class GatherJob < ActiveJob::Base
    include ScatterGather
    discard_on DependencyTimeoutError

    def logger = ActiveSupport::TaggedLogging.new(super).tagged("ScatterGather")

    def perform(wait_for_active_job_ids:, target_job:, gather_config:, remaining_attempts:)
      deps = ScatterGather::Completion.collect_statuses(wait_for_active_job_ids)
      logger.info { "Gathered completions #{tally_in_logger_format(deps)}" }

      all_done = deps.values.all? { |it| it == :completed }
      if all_done
        logger.info { "Dependencies done, enqueueing #{target_job.fetch(:cn)}" }
        perform_target_later_from_args(target_job)
        Completion.where(active_job_id: wait_for_active_job_ids).delete_all
      elsif remaining_attempts < 1
        max_attempts = gather_config.fetch(:max_attempts)
        error = DependencyTimeoutError.new(max_attempts, deps)
        logger.warn { "Failed to gather dependencies after #{max_attempts} attempts" }
        Completion.where(active_job_id: wait_for_active_job_ids).delete_all

        # We configure our job to discard on timeout, and discard does not report the error by default
        Rails.error.report(error)
        raise error
      else
        # Re-enqueue with delay. We could poll only for dependencies which are still remaining,
        # but for debugging this is actually worse because for hanging stuff there will be one
        # job that hangs in the end. Knowing which jobs were part of the batch is useful!
        args = {
          wait_for_active_job_ids:,
          target_job:,
          gather_config:,
          remaining_attempts: remaining_attempts - 1
        }
        wait = gather_config.fetch(:poll_interval)
        self.class.set(wait:).perform_later(**args)
      end
    end

    private

    def tally_in_logger_format(hash)
      hash.values.tally.map do |k, count|
        "#{k}=#{count}"
      end.join(" ")
    end

    def perform_target_later_from_args(target_job)
      # The only purpose of this is to pass all variations
      # of `perform_later` argument shapes correctly
      job_class = target_job.fetch(:cn).constantize
      if target_job[:p].any? && target_job[:k] # Both
        job_class.perform_later(*target_job[:p], **target_job[:k])
      elsif target_job[:k] # Just kwargs
        job_class.perform_later(**target_job[:k])
      elsif target_job[:p] # Just posargs
        job_class.perform_later(*target_job[:p])
      else
        job_class.perform_later # No args
      end
    end
  end

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
      ScatterGather::Completion.insert_all(attrs)
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
