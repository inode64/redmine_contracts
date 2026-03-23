# frozen_string_literal: true

class AddImputationVersionIdsToRedmineContracts < ActiveRecord::Migration[6.1]
  def change
    add_column :redmine_contracts, :imputation_version_ids, :text
  end
end
