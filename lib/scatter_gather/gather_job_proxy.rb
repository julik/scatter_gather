# frozen_string_literal: true

# Proxy class that mimics ActiveJob behavior for gather jobs
class ScatterGather::GatherJobProxy
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
    ScatterGather::GatherJob.perform_later(**gather_job_params)
  end
end
