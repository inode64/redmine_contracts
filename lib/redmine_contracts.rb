# frozen_string_literal: true

require_relative 'redmine_contracts/patches/project_patch'
require_relative 'redmine_contracts/patches/time_entry_patch'

module RedmineContracts
  module Patches
    def self.apply
      Project.include(RedmineContracts::Patches::ProjectPatch)
      TimeEntry.include(RedmineContracts::Patches::TimeEntryPatch)
    end
  end
end
