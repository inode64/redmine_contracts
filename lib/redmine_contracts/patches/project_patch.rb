# frozen_string_literal: true

require_dependency 'project'

module RedmineContracts
  module Patches
    module ProjectPatch
      def self.included(base)
        base.class_eval do
          has_many :hour_contracts,
                   class_name: 'RedmineContracts::Contract',
                   foreign_key: :project_id,
                   inverse_of: :project,
                   dependent: :destroy
        end
      end
    end
  end
end
