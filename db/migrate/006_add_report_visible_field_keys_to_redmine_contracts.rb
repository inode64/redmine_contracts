# frozen_string_literal: true

class AddReportVisibleFieldKeysToRedmineContracts < ActiveRecord::Migration[6.1]
  def change
    add_column :redmine_contracts, :report_visible_field_keys, :text
  end
end
