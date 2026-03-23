# frozen_string_literal: true

class AddImputationCustomFieldToRedmineContracts < ActiveRecord::Migration[6.1]
  def change
    add_column :redmine_contracts, :imputation_custom_field_id, :integer
    add_index :redmine_contracts, :imputation_custom_field_id
  end
end
