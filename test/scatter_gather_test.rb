require "test_helper"
require "ostruct"

class ScatterGatherTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    tempdir_name = "scatter-gather-tests-#{Random.uuid}"
    @tempdir = Rails.root.join("tmp", tempdir_name)
    FileUtils.mkdir_p(@tempdir)
  end

  teardown do
    ScatterGather::Completion.delete_all
    FileUtils.rm_rf(@tempdir)
  end

  def tempfile_path
    File.join(@tempdir, "#{Random.uuid}.bin")
  end

  class TouchingJob < ActiveJob::Base
    include ScatterGather

    def perform(path)
      File.binwrite(path, "Y")
    end
  end

  class FailingJob < ActiveJob::Base
    include ScatterGather

    class Particular < StandardError
    end

    retry_on Particular, attempts: 3

    def perform
      raise Particular
    end
  end

  test "also accepts splatted jobs" do
    paths = 3.times.map { tempfile_path }
    jobs = paths.map { |path| TouchingJob.perform_later(path) }

    final_path = tempfile_path
    TouchingJob.gather(*jobs).perform_later(final_path)

    assert_enqueued_jobs paths.length + 1
  end

  test "waits for jobs to complete before performing the final job" do
    paths = 5.times.map { tempfile_path }
    jobs = paths.map { |path| TouchingJob.perform_later(path) }

    final_path = tempfile_path
    TouchingJob.gather(jobs).perform_later(final_path)

    assert_enqueued_jobs paths.length + 1
    perform_enqueued_jobs # Performs the dependencies and the gather job

    assert paths.all? { |path| File.exist?(path) }
    assert_enqueued_jobs 1 # which then enqueues the final touching job
    refute File.exist?(final_path)

    perform_enqueued_jobs
    assert File.exist?(final_path)
  end

  test "polls for jobs repeatedly and does not perform the final job if one job never runs" do
    paths = 3.times.map { tempfile_path }

    jobs = paths.map { |path| TouchingJob.perform_later(path) }
    jobs << OpenStruct.new(job_id: "missing") # Will never become an actual job nor will it run

    final_path = tempfile_path
    TouchingJob.gather(jobs, poll_interval: 0.2).perform_later(final_path)

    assert_enqueued_jobs paths.length + 1 # No job was actually enqueued for our last missing one
    perform_enqueued_jobs # Performs the dependencies and the gather job

    loop do
      break if enqueued_jobs.length.zero?
      travel_to Time.current + 0.3
      perform_enqueued_jobs
    end
    refute File.exist?(final_path) # Should never have run
  end

  def perform_and_rescue
    perform_enqueued_jobs
  rescue FailingJob::Particular
  end

  test "limits polling to max_attempts" do
    jobs = [OpenStruct.new(job_id: "missing")] # Will never become an actual job nor will it run

    final_path = tempfile_path
    TouchingJob.gather(jobs, poll_interval: 0, max_attempts: 4).perform_later(final_path)

    polls_done = 0
    loop do
      break if enqueued_jobs.length.zero?
      polls_done += 1
      perform_enqueued_jobs
    end

    refute File.exist?(final_path)
    assert_equal polls_done, 4
  end

  test "polls for jobs repeatedly and does not perform the final job if one job fails all the time" do
    paths = 3.times.map { tempfile_path }
    jobs = paths.map { |path| TouchingJob.perform_later(path) }
    jobs << FailingJob.perform_later

    final_path = tempfile_path
    TouchingJob.gather(jobs, poll_interval: 0.2).perform_later(final_path)

    assert_enqueued_jobs jobs.length + 1
    perform_and_rescue
    loop do
      break if enqueued_jobs.length.zero?
      travel_to Time.current + 0.3
      perform_and_rescue
    end
    refute File.exist?(final_path) # Should never have run
  end

  class NoArgsJob < ActiveJob::Base
    include ScatterGather
    def perform
      # no-op
    end
  end

  class PosargsJob < ActiveJob::Base
    include ScatterGather
    def perform(a, b)
      # no-op
    end
  end

  class KwargsJob < ActiveJob::Base
    include ScatterGather
    def perform(a:, b:, **rest)
      # no-op
    end
  end

  class CombiArgsJob < ActiveJob::Base
    include ScatterGather
    def perform(a, b:, **rest)
      # no-op
    end
  end

  test "correctly passes arguments for perform() of the target job" do
    assert_nothing_raised do
      NoArgsJob.gather([]).perform_later
      perform_enqueued_jobs
    end

    assert_nothing_raised do
      PosargsJob.gather([]).perform_later(1, 2)
      perform_enqueued_jobs
    end

    assert_nothing_raised do
      KwargsJob.gather([]).perform_later(a: 1, b: 2)
      perform_enqueued_jobs
    end

    assert_nothing_raised do
      CombiArgsJob.gather([]).perform_later(1, b: 2, extra: "hello")
      perform_enqueued_jobs
    end
  end

  test "Completion.collect_statuses handles missing job IDs correctly" do
    # Create some job IDs - some that exist in the database, some that don't
    existing_job_id_1 = "existing-job-1"
    existing_job_id_2 = "existing-job-2"
    missing_job_id_1 = "missing-job-1"
    missing_job_id_2 = "missing-job-2"

    # Create completion records for some jobs
    ScatterGather::Completion.create!(
      active_job_id: existing_job_id_1,
      active_job_class_name: "TestJob",
      status: "completed"
    )

    ScatterGather::Completion.create!(
      active_job_id: existing_job_id_2,
      active_job_class_name: "TestJob",
      status: "pending"
    )

    # Test with a mix of existing and missing job IDs
    job_ids = [existing_job_id_1, existing_job_id_2, missing_job_id_1, missing_job_id_2]

    # Call the method and capture the result
    result = ScatterGather::Completion.collect_statuses(job_ids)

    # Verify the results
    existing_completed = result.find { |ds| ds.active_job_id == existing_job_id_1 }
    existing_pending = result.find { |ds| ds.active_job_id == existing_job_id_2 }
    missing_1 = result.find { |ds| ds.active_job_id == missing_job_id_1 }
    missing_2 = result.find { |ds| ds.active_job_id == missing_job_id_2 }

    assert_not_nil existing_completed, "Should find existing completed job"
    assert_equal :completed, existing_completed.status, "Existing completed job should have :completed status"
    assert_equal "TestJob", existing_completed.active_job_class, "Should have correct class name"
    assert_equal "✓", existing_completed.checkmark, "Completed job should have checkmark"

    assert_not_nil existing_pending, "Should find existing pending job"
    assert_equal :pending, existing_pending.status, "Existing pending job should have :pending status"
    assert_equal "TestJob", existing_pending.active_job_class, "Should have correct class name"
    assert_equal " ", existing_pending.checkmark, "Pending job should have space"

    assert_not_nil missing_1, "Should find missing job 1"
    assert_equal :unknown, missing_1.status, "Missing job should have :unknown status"
    assert_nil missing_1.active_job_class, "Missing job should have nil class name"
    assert_equal "(unknown)", missing_1.display_class, "Should display (unknown) for missing class"
    assert_equal " ", missing_1.checkmark, "Unknown job should have space"

    assert_not_nil missing_2, "Should find missing job 2"
    assert_equal :unknown, missing_2.status, "Missing job should have :unknown status"
    assert_nil missing_2.active_job_class, "Missing job should have nil class name"
    assert_equal "(unknown)", missing_2.display_class, "Should display (unknown) for missing class"
    assert_equal " ", missing_2.checkmark, "Unknown job should have space"

    # Verify all job IDs are present in the result
    assert_equal job_ids.length, result.length, "Result should contain all job IDs"
    result_job_ids = result.map(&:active_job_id)
    job_ids.each do |job_id|
      assert_includes result_job_ids, job_id, "Result should contain job ID: #{job_id}"
    end
  end

  test "DependencyTimeoutError formats dependency table correctly" do
    # Create some dependency statuses with mixed states
    dependency_statuses = [
      ScatterGather::DependencyStatus.new("job-1", "TestJob", :completed),
      ScatterGather::DependencyStatus.new("job-2", "AnotherJob", :pending),
      ScatterGather::DependencyStatus.new("job-3", nil, :unknown),
      ScatterGather::DependencyStatus.new("job-4", "LongClassNameJob", :pending)
    ]

    # Create the exception
    error = ScatterGather::DependencyTimeoutError.new(5, dependency_statuses)

    # Verify the exception has the correct attributes
    assert_equal 5, error.max_attempts
    assert_equal dependency_statuses, error.dependency_statuses

    # Test the exact table format
    expected_message = <<~MSG
      Gather failed after 5 attempts. Dependencies:

      | ✓ | Job ID | Class            | Status    |
      |---|--------|------------------|-----------|
      | ✓ | job-1  | TestJob          | completed |
      |   | job-2  | AnotherJob       | pending   |
      |   | job-3  | (unknown)        | unknown   |
      |   | job-4  | LongClassNameJob | pending   |
    MSG

    assert_equal expected_message, error.message
  end
end
