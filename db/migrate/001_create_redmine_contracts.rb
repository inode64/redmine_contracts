# frozen_string_literal: true

class CreateRedmineContracts < ActiveRecord::Migration[6.1]
  def change
    create_table :redmine_contracts, id: :integer do |t|
      t.integer :project_id, null: false
      t.string :name, null: false
      t.date :started_on, null: false
      t.string :status, null: false, default: 'active'
      t.text :notes
      t.timestamps
    end
    add_index :redmine_contracts, :project_id
    add_foreign_key :redmine_contracts, :projects, column: :project_id

    create_table :redmine_contract_bonuses, id: :integer do |t|
      t.integer :contract_id, null: false
      t.date :awarded_on, null: false
      t.string :name, null: false
      t.string :invoice_reference
      t.decimal :hours_total, precision: 10, scale: 2, null: false
      t.timestamps
    end
    add_index :redmine_contract_bonuses, :contract_id
    add_foreign_key :redmine_contract_bonuses, :redmine_contracts, column: :contract_id

    add_reference :time_entries, :contract, type: :integer, index: true, foreign_key: { to_table: :redmine_contracts }
  end
end
