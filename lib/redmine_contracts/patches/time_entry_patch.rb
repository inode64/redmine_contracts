# frozen_string_literal: true

require_dependency 'time_entry'

module RedmineContracts
  module Patches
    module TimeEntryPatch
      extend ActiveSupport::Concern

      included do
        belongs_to :contract,
                   class_name: 'RedmineContracts::Contract',
                   foreign_key: :contract_id,
                   inverse_of: :time_entries,
                   optional: true

        before_validation :assign_active_contract, on: :create
        after_commit :recalculate_contracts_on_create, on: :create
        after_commit :recalculate_contracts_on_update, on: :update
        after_commit :recalculate_contracts_on_destroy, on: :destroy
      end

      private

      RELEVANT_RECALCULATION_FIELDS = %w[hours spent_on issue_id project_id contract_id].freeze

      def assign_active_contract
        return if contract_id.present?

        source_project = issue&.project || project
        return unless source_project

        active_contract = RedmineContracts::Contract.active_for_project(source_project, self)
        self.contract = active_contract if active_contract
      end

      def recalculate_contracts_on_create
        recalculate_contracts!(contract_ids_for_recalculation_after_create)
      end

      def recalculate_contracts_on_update
        return unless previous_changes.keys.intersect?(RELEVANT_RECALCULATION_FIELDS)

        recalculate_contracts!(contract_ids_for_recalculation_after_update)
      end

      def recalculate_contracts_on_destroy
        recalculate_contracts!(contract_ids_for_recalculation_after_destroy)
      end

      def recalculate_contracts!(contract_ids)
        Array(contract_ids).compact.uniq.each do |contract_id|
          RedmineContracts::Contract.find_by(id: contract_id)&.recalculate_bonus_spent_hours!
        end
      end

      def contract_ids_for_recalculation_after_create
        ids = []
        ids << contract_id if contract_id.present?
        ids.concat(contract_ids_for_source_projects([current_source_project_id])) if ids.empty?
        ids.compact.uniq
      end

      def contract_ids_for_recalculation_after_update
        ids = []
        if previous_changes.key?('contract_id')
          old_id, new_id = previous_changes['contract_id']
          ids.concat([old_id, new_id])
        else
          ids << contract_id if contract_id.present?
        end

        if ids.compact.empty?
          source_project_ids = [current_source_project_id]
          source_project_ids.concat(previous_source_project_ids)
          ids.concat(contract_ids_for_source_projects(source_project_ids))
        end

        ids.compact.uniq
      end

      def contract_ids_for_recalculation_after_destroy
        old_contract_id = previous_changes['contract_id']&.first
        return [old_contract_id] if old_contract_id.present?

        contract_ids_for_source_projects(previous_source_project_ids)
      end

      def current_source_project_id
        issue&.project_id || project_id
      end

      def previous_source_project_ids
        old_issue_id = previous_changes['issue_id']&.first
        old_project_id = previous_changes['project_id']&.first

        source_ids = []
        source_ids << resolve_source_project_id(old_issue_id, old_project_id)
        source_ids << resolve_source_project_id(issue_id, project_id)
        source_ids.compact.uniq
      end

      def resolve_source_project_id(issue_id_value, project_id_value)
        issue_project_id = issue_id_value.present? ? Issue.where(id: issue_id_value).pick(:project_id) : nil
        issue_project_id || project_id_value
      end

      def contract_ids_for_source_projects(source_project_ids)
        Array(source_project_ids).filter_map do |source_project_id|
          project = Project.find_by(id: source_project_id)
          next unless project

          lineage_ids = RedmineContracts::Contract.project_lineage_ids(project)
          RedmineContracts::Contract.active.where(project_id: lineage_ids).select do |candidate_contract|
            candidate_contract.applies_to_project?(project)
          end.map(&:id)
        end.flatten.uniq
      end
    end
  end
end
