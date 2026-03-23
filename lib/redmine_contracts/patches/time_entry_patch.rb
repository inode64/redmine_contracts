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
      end

      private

      def assign_active_contract
        return if contract_id.present?

        source_project = issue&.project || project
        return unless source_project

        active_contract = RedmineContracts::Contract.active_for_project(source_project, self)
        self.contract = active_contract if active_contract
      end
    end
  end
end
