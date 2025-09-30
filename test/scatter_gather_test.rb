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
end
