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

  test "smoke test: clean gem installation succeeds" do
    dummy_app_root = Rails.root
    original_cwd = Dir.pwd

    begin
      # Change to dummy app directory
      Dir.chdir(dummy_app_root)

      # Step 1: Clean up existing migrations and database to simulate clean installation
      puts "Step 1: Cleaning up existing migrations and database..."

      # Remove any existing scatter_gather migration files
      existing_migrations = Dir.glob(File.join(dummy_app_root, "db", "migrate", "*scatter_gather*"))
      existing_migrations.each { |file| File.delete(file) }

      result = system("bundle exec rails db:drop", out: File::NULL, err: File::NULL)
      assert result, "Database drop should succeed"

      # Step 2: Create fresh database
      puts "Step 2: Creating fresh database..."
      result = system("bundle exec rails db:create", out: File::NULL, err: File::NULL)
      assert result, "Database create should succeed"

      # Step 3: Manually run the generator to create migration (since gem isn't loaded in dummy app)
      puts "Step 3: Running scatter_gather:install generator..."
      require "scatter_gather"
      require_relative "../lib/generators/install_generator"

      # Create a temporary generator instance and run it
      generator = ScatterGather::InstallGenerator.new
      generator.create_migration_file

      # Step 4: Verify migration file was created
      puts "Step 4: Verifying migration file was created..."
      migration_files = Dir.glob(File.join(dummy_app_root, "db", "migrate", "*_scatter_gather_migration_001.rb"))
      assert_equal 1, migration_files.length, "Should create exactly one migration file"

      migration_file = migration_files.first
      assert File.exist?(migration_file), "Migration file should exist"

      # Step 5: Verify migration content includes ID detection logic
      puts "Step 5: Verifying migration content..."
      migration_content = File.read(migration_file)
      assert_includes migration_content, "detect_dominant_id_type", "Migration should include ID detection method"
      assert_includes migration_content, "table_options = id_type == :uuid ? { id: :uuid } : {}", "Migration should use conditional ID type"
      assert_includes migration_content, "create_table :scatter_gather_completions", "Migration should create the correct table"

      # Step 6: Run migrations
      puts "Step 6: Running migrations..."
      result = system("bundle exec rails db:migrate", out: File::NULL, err: File::NULL)
      assert result, "Migrations should succeed"

      # Step 7: Verify table was created with correct structure
      puts "Step 7: Verifying table structure..."
      table_exists = ActiveRecord::Base.connection.table_exists?(:scatter_gather_completions)
      assert table_exists, "scatter_gather_completions table should exist"

      # Verify ID column type (should be integer for clean database)
      id_column = ActiveRecord::Base.connection.columns(:scatter_gather_completions).find { |col| col.name == "id" }
      assert_not_nil id_column, "ID column should exist"
      assert_equal :integer, id_column.type, "ID column should be integer type for clean database"

      # Verify other columns exist
      column_names = ActiveRecord::Base.connection.columns(:scatter_gather_completions).map(&:name)
      assert_includes column_names, "active_job_id", "active_job_id column should exist"
      assert_includes column_names, "active_job_class_name", "active_job_class_name column should exist"
      assert_includes column_names, "status", "status column should exist"
      assert_includes column_names, "created_at", "created_at column should exist"
      assert_includes column_names, "updated_at", "updated_at column should exist"

      # Step 8: Verify indexes were created
      puts "Step 8: Verifying indexes..."
      indexes = ActiveRecord::Base.connection.indexes(:scatter_gather_completions)
      active_job_id_index = indexes.find { |idx| idx.columns == ["active_job_id"] }
      assert_not_nil active_job_id_index, "active_job_id index should exist"
      assert active_job_id_index.unique, "active_job_id index should be unique"

      created_at_index = indexes.find { |idx| idx.columns == ["created_at"] }
      assert_not_nil created_at_index, "created_at index should exist"

      # Step 9: Verify Completion model works via Rails runner
      puts "Step 9: Verifying Completion model via Rails runner..."
      result = system("bundle exec rails runner 'puts ScatterGather::Completion.count'", out: File::NULL, err: File::NULL)
      assert result, "Rails runner should succeed"

      # Capture the output to verify count is 0
      output = `bundle exec rails runner 'puts ScatterGather::Completion.count' 2>/dev/null`.strip
      assert_equal "0", output, "Completion count should be 0 for fresh installation"

      puts "Smoke test completed successfully!"
    ensure
      # Restore original working directory
      Dir.chdir(original_cwd)
    end
  end
end
