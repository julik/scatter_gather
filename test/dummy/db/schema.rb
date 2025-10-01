# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2025_01_01_000001) do
  create_table "scatter_gather_completions", force: :cascade do |t|
    t.string "active_job_id", null: false
    t.string "active_job_class_name"
    t.string "status", default: "unknown"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_scatter_gather_completions_on_active_job_id", unique: true
    t.index ["created_at"], name: "index_scatter_gather_completions_on_created_at"
  end
end
