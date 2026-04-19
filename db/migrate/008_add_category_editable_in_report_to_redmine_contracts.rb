# frozen_string_literal: true

class AddCategoryEditableInReportToRedmineContracts < ActiveRecord::Migration[6.1]
  def change
    add_column :redmine_contracts, :category_editable_in_report, :boolean, default: false, null: false
  end
end
