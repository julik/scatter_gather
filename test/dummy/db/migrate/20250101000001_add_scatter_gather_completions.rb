class AddScatterGatherCompletions < ActiveRecord::Migration[7.2]
  def up
    create_table :scatter_gather_completions do |t|
      t.string :active_job_id, null: false
      t.string :active_job_class_name
      t.string :status, default: "unknown"
      t.timestamps
    end
    add_index :scatter_gather_completions, [:active_job_id], unique: true # For lookups
    add_index :scatter_gather_completions, [:created_at] # For cleanup
  end

  def down
    drop_table :scatter_gather_completions
  end
end
