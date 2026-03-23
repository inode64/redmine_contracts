# frozen_string_literal: true

class AddHoursSpentCacheToRedmineContractBonuses < ActiveRecord::Migration[6.1]
  def change
    add_column :redmine_contract_bonuses, :hours_spent_cache, :decimal, precision: 10, scale: 2
  end
end
