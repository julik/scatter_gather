require "test_helper"

class SmokeTest < ActiveSupport::TestCase
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

      result = system("bundle exec rails db:drop RAILS_ENV=test", out: File::NULL, err: File::NULL)
      assert result, "Database drop should succeed"

      # Step 2: Create fresh database
      puts "Step 2: Creating fresh database..."
      result = system("bundle exec rails db:create RAILS_ENV=test", out: File::NULL, err: File::NULL)
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
      migration_files = Dir.glob(File.join(dummy_app_root, "db", "migrate", "*scatter_gather_migration_001.rb"))
      assert_equal 1, migration_files.length, "Should create exactly one migration file"

      migration_file = migration_files.first
      assert File.exist?(migration_file), "Migration file should exist"

      # Step 5: Verify migration content includes ID detection logic
      puts "Step 5: Verifying migration content..."
      migration_content = File.read(migration_file)
      assert_includes migration_content, "detect_dominant_id_type", "Migration should include ID detection method"
      assert_includes migration_content, "table_options =", "Migration should use conditional ID type"
      assert_includes migration_content, "id_type == :uuid", "Migration should check for UUID type"
      assert_includes migration_content, "create_table :scatter_gather_completions", "Migration should create the correct table"

      # Step 6: Run migrations
      puts "Step 6: Running migrations..."
      result = system("bundle exec rails db:migrate RAILS_ENV=test", out: File::NULL, err: File::NULL)
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
