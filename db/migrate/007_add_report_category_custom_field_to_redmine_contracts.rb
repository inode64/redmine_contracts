# frozen_string_literal: true

class AddReportCategoryCustomFieldToRedmineContracts < ActiveRecord::Migration[6.1]
  def change
    add_column :redmine_contracts, :report_category_custom_field_id, :integer
    add_index :redmine_contracts, :report_category_custom_field_id
  end
end
