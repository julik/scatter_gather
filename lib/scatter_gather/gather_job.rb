# frozen_string_literal: true

# Internal job class for polling and coordinating gather operations
class ScatterGather::GatherJob < ActiveJob::Base
  include ScatterGather
  discard_on ScatterGather::DependencyTimeoutError

  def logger = ActiveSupport::TaggedLogging.new(super).tagged("ScatterGather")

  def perform(wait_for_active_job_ids:, target_job:, gather_config:, remaining_attempts:)
    dependency_statuses = ScatterGather::Completion.collect_statuses(wait_for_active_job_ids)
    logger.info { "Gathered completions #{tally_in_logger_format(dependency_statuses)}" }

    if ScatterGather::Completion.all_dependencies_completed?(dependency_statuses)
      logger.info { "Dependencies done, enqueueing #{target_job.fetch(:cn)}" }
      perform_target_later_from_args(target_job)
      ScatterGather::Completion.where(active_job_id: wait_for_active_job_ids).delete_all
    elsif remaining_attempts < 1
      max_attempts = gather_config.fetch(:max_attempts)
      error = ScatterGather::DependencyTimeoutError.new(max_attempts, dependency_statuses)
      logger.warn { "Failed to gather dependencies after #{max_attempts} attempts" }
      ScatterGather::Completion.where(active_job_id: wait_for_active_job_ids).delete_all

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
      wait = gather_config.fetch(:poll_interval).seconds
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
