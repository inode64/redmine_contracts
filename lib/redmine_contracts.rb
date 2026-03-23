# frozen_string_literal: true

require_relative 'redmine_contracts/patches/project_patch'
require_relative 'redmine_contracts/patches/time_entry_patch'

module RedmineContracts
  module Patches
    def self.apply
      require_dependency 'project'
      require_dependency 'time_entry'

      unless Project.included_modules.include?(RedmineContracts::Patches::ProjectPatch)
        Project.send(:include, RedmineContracts::Patches::ProjectPatch)
      end

      unless TimeEntry.included_modules.include?(RedmineContracts::Patches::TimeEntryPatch)
        TimeEntry.send(:include, RedmineContracts::Patches::TimeEntryPatch)
      end
    end
  end
end
