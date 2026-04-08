# frozen_string_literal: true

module RedmineContracts
  class ContractBonus < ApplicationRecord
    self.table_name = 'redmine_contract_bonuses'

    belongs_to :contract,
               class_name: 'RedmineContracts::Contract',
               foreign_key: :contract_id,
               inverse_of: :bonuses

    validates :awarded_on, presence: true
    validates :name, presence: true
    validates :hours_total, presence: true, numericality: { greater_than: 0 }
    validates :hours_spent_cache, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

    after_commit :recalculate_contract_on_create, on: :create
    after_commit :recalculate_contract_on_destroy, on: :destroy
    after_commit :recalculate_contract_on_update, on: :update

    def self.next_correlative_name(previous_name)
      base_name = previous_name.to_s.strip
      if base_name.blank?
        default_prefix = I18n.t(:label_redmine_contract_bonus_default_prefix, default: 'Bonus')
        return "#{default_prefix} 1"
      end

      match = base_name.match(/\A(.*?)(\d+)\z/)
      return "#{base_name} 2" unless match

      prefix = match[1]
      current_digits = match[2]
      next_number = current_digits.to_i + 1
      "#{prefix}#{next_number.to_s.rjust(current_digits.length, '0')}".strip
    end

    private

    def recalculate_contract_on_create
      contract&.recalculate_bonus_spent_hours!
    end

    def recalculate_contract_on_destroy
      contract_for_recalculation&.recalculate_bonus_spent_hours!
    end

    def recalculate_contract_on_update
      return unless previous_changes.keys.intersect?(%w[hours_total awarded_on contract_id])

      if previous_changes.key?('contract_id')
        old_id, new_id = previous_changes['contract_id']
        RedmineContracts::Contract.find_by(id: old_id)&.recalculate_bonus_spent_hours!
        RedmineContracts::Contract.find_by(id: new_id)&.recalculate_bonus_spent_hours!
      else
        contract&.recalculate_bonus_spent_hours!
      end
    end

    def contract_for_recalculation
      contract || RedmineContracts::Contract.find_by(id: contract_id)
    end
  end
end
