# frozen_string_literal: true

class AddAppliedSubprojectIdsToRedmineContracts < ActiveRecord::Migration[6.1]
  def change
    add_column :redmine_contracts, :applied_subproject_ids, :text
  end
end
