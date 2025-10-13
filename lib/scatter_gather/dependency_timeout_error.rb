# frozen_string_literal: true

# Custom exception for when gather job exhausts attempts
class ScatterGather::DependencyTimeoutError < StandardError
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
