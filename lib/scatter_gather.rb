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

  # Struct to represent the status of a dependency job
  # @param active_job_id [String] The ActiveJob ID
  # @param active_job_class [String] The ActiveJob class name
  # @param status [Symbol] The status of the job (:completed, :pending, :unknown)
  DependencyStatus = Struct.new(:active_job_id, :active_job_class, :status) do
    # Get a display-friendly class name for unknown jobs
    # @return [String] The class name or "(unknown)" for unknown jobs
    def display_class
      active_job_class || "(unknown)"
    end

    # Get a checkmark for completed jobs
    # @return [String] "✓" for completed jobs, " " for others
    def checkmark
      (status == :completed) ? "✓" : " "
    end
  end

  class Completion < ActiveRecord::Base
    self.table_name = "scatter_gather_completions"

    # Collect status information for the given active job IDs
    # @param active_job_ids [Array<String>] Array of ActiveJob IDs to check
    # @return [Array<DependencyStatus>] Array of DependencyStatus objects
    def self.collect_statuses(active_job_ids)
      # Initialize all job IDs with unknown status
      statuses = active_job_ids.map { |id| [id, :unknown] }.to_h

      # Get statuses from completion records
      completions = where(active_job_id: active_job_ids)
        .pluck(:active_job_id, :active_job_class_name, :status)
        .map do |(id, class_name, status)|
          [id, {class_name: class_name, status: status.to_sym}]
        end.to_h

      # Update statuses with completion data
      completions.each do |id, data|
        statuses[id] = data[:status]
      end

      # Create DependencyStatus objects
      dependency_statuses = active_job_ids.map do |id|
        completion_data = completions[id]
        class_name = completion_data&.dig(:class_name)
        status = statuses[id]

        DependencyStatus.new(id, class_name, status)
      end

      # Sort by status first (unknown, pending, completed), then by active_job_id
      dependency_statuses.sort_by do |ds|
        status_order = case ds.status
        when :unknown then 0
        when :pending then 1
        when :completed then 2
        else 3
        end
        [status_order, ds.active_job_id.to_s]
      end
    end

    # Check if all dependencies are completed
    # @param dependency_statuses [Array<DependencyStatus>] Array of dependency statuses
    # @return [Boolean] true if all dependencies are completed
    def self.all_dependencies_completed?(dependency_statuses)
      dependency_statuses.all? { |ds| ds.status == :completed }
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
    attr_reader :dependency_statuses, :max_attempts

    def initialize(max_attempts, dependency_statuses)
      @max_attempts = max_attempts
      @dependency_statuses = dependency_statuses
      super(<<~MSG)
        Gather failed after #{max_attempts} attempts. Dependencies:
        
        #{format_dependency_table(dependency_statuses)}
      MSG
    end

    private

    # Format dependency statuses as a plaintext table
    # @param dependency_statuses [Array<DependencyStatus>] Array of dependency statuses
    # @return [String] Formatted table string
    def format_dependency_table(dependency_statuses)
      return "No dependencies" if dependency_statuses.empty?

      # Calculate column widths
      max_id_width = dependency_statuses.map { |ds| ds.active_job_id.length }.max || 0
      max_class_width = dependency_statuses.map { |ds| ds.display_class.length }.max || 0
      max_status_width = dependency_statuses.map { |ds| ds.status.to_s.length }.max || 0

      # Ensure minimum widths
      id_width = [max_id_width, 6].max # "Job ID".length = 6
      class_width = [max_class_width, 5].max # "Class".length = 5
      status_width = [max_status_width, 5].max # "Status".length = 5

      # Build table
      lines = []

      # Header
      header = "| ✓ | %-#{id_width}s | %-#{class_width}s | %-#{status_width}s |" % ["Job ID", "Class", "Status"]
      lines << header
      lines << "|---|#{"-" * (id_width + 2)}|#{"-" * (class_width + 2)}|#{"-" * (status_width + 2)}|"

      # Rows (dependency_statuses are already sorted from collect_statuses)
      dependency_statuses.each do |ds|
        row = "| %s | %-#{id_width}s | %-#{class_width}s | %-#{status_width}s |" % [
          ds.checkmark,
          ds.active_job_id,
          ds.display_class,
          ds.status.to_s
        ]
        lines << row
      end

      lines.join("\n")
    end
  end

  # Internal job class for polling and coordinating gather operations
  class GatherJob < ActiveJob::Base
    include ScatterGather
    discard_on DependencyTimeoutError

    def logger = ActiveSupport::TaggedLogging.new(super).tagged("ScatterGather")

    def perform(wait_for_active_job_ids:, target_job:, gather_config:, remaining_attempts:)
      dependency_statuses = ScatterGather::Completion.collect_statuses(wait_for_active_job_ids)
      logger.info { "Gathered completions #{tally_in_logger_format(dependency_statuses)}" }

      if ScatterGather::Completion.all_dependencies_completed?(dependency_statuses)
        logger.info { "Dependencies done, enqueueing #{target_job.fetch(:cn)}" }
        perform_target_later_from_args(target_job)
        Completion.where(active_job_id: wait_for_active_job_ids).delete_all
      elsif remaining_attempts < 1
        max_attempts = gather_config.fetch(:max_attempts)
        error = DependencyTimeoutError.new(max_attempts, dependency_statuses)
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

    def tally_in_logger_format(dependency_statuses)
      dependency_statuses.map(&:status).tally.map do |status, count|
        "#{status}=#{count}"
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
