# frozen_string_literal: true

# Struct to represent the status of a dependency job
# @param active_job_id [String] The ActiveJob ID
# @param active_job_class [String] The ActiveJob class name
# @param status [Symbol] The status of the job (:completed, :pending, :unknown)
ScatterGather::DependencyStatus = Struct.new(:active_job_id, :active_job_class, :status) do
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
