# frozen_string_literal: true

# ActiveJob itself does not maintain a "one record per job" database entry where we could reliably track job completion.
# The underlying job storage (e.g., Sidekiq, Que, DelayedJob) is determined by the ActiveJob adapter, and their implementation details vary.
# As a result, to enable reliable scatter-gather orchestration, we create our own completion tracking records.
# Each job that is meant to be gathered later inserts a record into the scatter_gather_completions table when it is enqueued,
# and marks it as completed upon finishing. This ensures adapter-independent, uniform dependency tracking.
class ScatterGather::Completion < ActiveRecord::Base
  self.table_name = "scatter_gather_completions"

  # Bulk insert completion rows if they do not already exist, without
  # overwriting existing rows on conflict.
  #
  # @param rows [Array<Hash>] array of attribute hashes with keys:
  #   :active_job_id, :active_job_class_name, :status, :created_at, :updated_at
  # @return [void]
  def self.insert_if_missing(rows)
    return if rows.empty?

    connection = ActiveRecord::Base.connection
    table = connection.quote_table_name(table_name)
    columns = %w[active_job_id active_job_class_name status created_at updated_at]
    quoted_columns = columns.map { |c| connection.quote_column_name(c) }.join(", ")

    values_sql = rows.map do |attrs|
      [
        connection.quote(attrs[:active_job_id]),
        connection.quote(attrs[:active_job_class_name]),
        connection.quote(attrs[:status]),
        connection.quote(attrs[:created_at]),
        connection.quote(attrs[:updated_at])
      ].join(", ")
    end.map { |vals| "(#{vals})" }.join(", ")

    # Use conflict target by column name to be portable across adapters
    conflict_target = connection.quote_column_name("active_job_id")

    sql = <<~SQL
      INSERT INTO #{table} (#{quoted_columns})
      VALUES #{values_sql}
      ON CONFLICT (#{conflict_target}) DO NOTHING
    SQL

    connection.execute(sql)
  end

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

      ScatterGather::DependencyStatus.new(id, class_name, status)
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
