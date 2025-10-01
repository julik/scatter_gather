require "test_helper"
require "fileutils"

class SmokeTest < ActiveSupport::TestCase
  test "smoke test: clean gem installation succeeds" do
    # Load the generator before changing directories
    require "scatter_gather"
    project_root = File.expand_path("../..", __FILE__)
    require File.join(project_root, "lib", "generators", "install_generator")

    # Create a temporary directory for the test
    temp_dir = Dir.mktmpdir("scatter_gather_smoke_test")
    dummy_app_source = Rails.root
    dummy_app_target = File.join(temp_dir, "dummy_app")
    original_cwd = Dir.pwd

    begin
      # Step 1: Copy dummy app to temporary directory
      puts "Step 1: Copying dummy app to temporary directory..."
      FileUtils.cp_r(dummy_app_source, dummy_app_target)

      # Change to the temporary dummy app directory
      Dir.chdir(dummy_app_target)

      # Step 2: Clean up any existing migrations and database
      puts "Step 2: Cleaning up existing migrations and database..."

      # Remove any existing scatter_gather migration files
      existing_migrations = Dir.glob(File.join(dummy_app_target, "db", "migrate", "*scatter_gather*"))
      existing_migrations.each { |file| File.delete(file) }

      result = system("bundle exec rails db:drop RAILS_ENV=test", out: File::NULL, err: File::NULL)
      assert result, "Database drop should succeed"

      # Step 3: Create fresh database
      puts "Step 3: Creating fresh database..."
      result = system("bundle exec rails db:create RAILS_ENV=test", out: File::NULL, err: File::NULL)
      assert result, "Database create should succeed"

      # Step 4: Manually run the generator to create migration
      puts "Step 4: Running scatter_gather:install generator..."

      # Create a temporary generator instance and run it
      generator = ScatterGather::InstallGenerator.new
      generator.create_migration_file

      # Step 5: Verify migration file was created
      puts "Step 5: Verifying migration file was created..."
      migration_files = Dir.glob(File.join(dummy_app_target, "db", "migrate", "*scatter_gather_migration_001.rb"))
      assert_equal 1, migration_files.length, "Should create exactly one migration file"

      migration_file = migration_files.first
      assert File.exist?(migration_file), "Migration file should exist"

      # Step 6: Verify migration content includes ID detection logic
      puts "Step 6: Verifying migration content..."
      migration_content = File.read(migration_file)
      assert_includes migration_content, "detect_dominant_id_type", "Migration should include ID detection method"
      assert_includes migration_content, "table_options =", "Migration should use conditional ID type"
      assert_includes migration_content, "id_type == :uuid", "Migration should check for UUID type"
      assert_includes migration_content, "create_table :scatter_gather_completions", "Migration should create the correct table"

      # Step 7: Run migrations
      puts "Step 7: Running migrations..."
      result = system("bundle exec rails db:migrate RAILS_ENV=test", out: File::NULL, err: File::NULL)
      assert result, "Migrations should succeed"

      # Step 8: Verify table was created with correct structure
      puts "Step 8: Verifying table structure..."
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

      # Step 9: Verify indexes were created
      puts "Step 9: Verifying indexes..."
      indexes = ActiveRecord::Base.connection.indexes(:scatter_gather_completions)
      active_job_id_index = indexes.find { |idx| idx.columns == ["active_job_id"] }
      assert_not_nil active_job_id_index, "active_job_id index should exist"
      assert active_job_id_index.unique, "active_job_id index should be unique"

      created_at_index = indexes.find { |idx| idx.columns == ["created_at"] }
      assert_not_nil created_at_index, "created_at index should exist"

      # Step 10: Verify Completion model works via Rails runner
      puts "Step 10: Verifying Completion model via Rails runner..."
      result = system("bundle exec rails runner 'puts ScatterGather::Completion.count'", out: File::NULL, err: File::NULL)
      assert result, "Rails runner should succeed"

      # Capture the output to verify count is 0
      output = `bundle exec rails runner 'puts ScatterGather::Completion.count' 2>/dev/null`.strip
      assert_equal "0", output, "Completion count should be 0 for fresh installation"

      puts "Smoke test completed successfully!"
    ensure
      # Restore original working directory
      Dir.chdir(original_cwd)

      # Clean up temporary directory
      FileUtils.rm_rf(temp_dir) if Dir.exist?(temp_dir)
    end
  end
end
