# frozen_string_literal: true

module RedmineContracts
  class Contract < ApplicationRecord
    self.table_name = 'redmine_contracts'

    belongs_to :project
    belongs_to :imputation_custom_field,
               class_name: 'IssueCustomField',
               foreign_key: :imputation_custom_field_id,
               optional: true

    has_many :bonuses,
             class_name: 'RedmineContracts::ContractBonus',
             foreign_key: :contract_id,
             inverse_of: :contract,
             dependent: :destroy

    has_many :time_entries,
             class_name: 'TimeEntry',
             foreign_key: :contract_id,
             inverse_of: :contract,
             dependent: :nullify

    validates :name, presence: true
    validates :started_on, presence: true
    validates :status, presence: true, inclusion: { in: %w[active closed] }
    validate :validate_imputation_custom_field
    validate :validate_imputation_versions
    validate :validate_applied_subprojects

    scope :for_project, lambda { |project|
      project_id = project.is_a?(Project) ? project.id : project
      where(project_id: project_id)
    }
    scope :for_projects, ->(project_ids) { where(project_id: Array(project_ids)) }
    scope :active, -> { where(status: 'active') }

    def imputation_custom_field_id
      read_optional_attribute(:imputation_custom_field_id)
    end

    def imputation_custom_field_id=(value)
      write_optional_attribute(:imputation_custom_field_id, value.presence)
    end

    def imputation_version_ids
      read_optional_attribute(:imputation_version_ids)
    end

    def imputation_version_ids=(value)
      normalized = normalize_version_ids(value)
      write_optional_attribute(:imputation_version_ids, normalized.join(','))
    end

    def applied_subproject_ids
      read_optional_attribute(:applied_subproject_ids)
    end

    def applied_subproject_ids=(value)
      normalized = normalize_project_ids(value)
      write_optional_attribute(:applied_subproject_ids, normalized.join(','))
    end

    def self.project_lineage_ids(project)
      current = project.is_a?(Project) ? project : Project.find_by(id: project)
      ids = []

      while current
        ids << current.id
        current = current.parent
      end

      ids
    end

    def self.visible_from_project(project)
      project_obj = project.is_a?(Project) ? project : Project.find_by(id: project)
      return [] unless project_obj

      for_projects(project_lineage_ids(project_obj))
        .includes(:project)
        .order(started_on: :desc, id: :desc)
        .select { |contract| contract.applies_to_project?(project_obj) }
    end

    def self.active_for_project(project, time_entry = nil)
      project_obj = project.is_a?(Project) ? project : Project.find_by(id: project)
      return nil unless project_obj

      project_lineage_ids(project_obj).each do |project_id|
        active.where(project_id: project_id).order(started_on: :desc, id: :desc).each do |contract|
          next unless contract.applies_to_project?(project_obj)

          return contract if time_entry.nil? || contract.imputable_time_entry?(time_entry)
        end
      end

      nil
    end

    def total_hours
      bonuses.sum(:hours_total).to_f
    end

    def spent_hours
      bonus_rows.sum { |row| row[:consumed_hours].to_f }
    end

    def remaining_hours
      total_hours - spent_hours
    end

    def bonus_rows
      return bonus_rows_from_cache if bonus_rows_cached?

      bonus_rows_fifo
    end

    def imputable_time_entry?(entry)
      source_project = entry.issue&.project || entry.project
      return false unless applies_to_project?(source_project)

      issue = entry.issue
      return false unless issue
      return false unless issue_version_allowed?(issue)
      return true if imputation_custom_field_id.blank?
      return false unless issue_has_custom_field?(issue, imputation_custom_field_id)

      truthy_custom_value?(issue.custom_field_value(imputation_custom_field_id))
    end

    def selected_version_ids
      normalize_version_ids(imputation_version_ids)
    end

    def selected_versions
      ids = selected_version_ids
      return [] if ids.empty?

      versions_by_id = Version.where(id: ids).index_by(&:id)
      ids.filter_map { |version_id| versions_by_id[version_id] }
    end

    def courtesy_rows
      return [] if started_on.blank? || imputation_custom_field_id.blank?

      courtesy_candidate_entries.filter_map do |entry|
        next unless courtesy_time_entry?(entry)

        {
          entry: entry,
          issue: entry.issue,
          project: entry.issue&.project || entry.project,
          hours: entry.hours.to_f
        }
      end
    end

    def courtesy_hours
      courtesy_rows.sum { |row| row[:hours] }
    end

    def report_rows
      report_candidate_entries.filter_map do |entry|
        next unless imputable_time_entry?(entry)

        issue = entry.issue
        {
          time_entry: entry,
          date: entry.spent_on || entry.created_on&.to_date,
          hours: entry.hours.to_f,
          issue: issue,
          project: issue&.project || entry.project,
          version: issue&.fixed_version
        }
      end
    end

    def selected_applied_subproject_ids
      normalize_project_ids(applied_subproject_ids)
    end

    def selected_applied_subprojects
      ids = selected_applied_subproject_ids
      return [] if ids.empty?

      projects_by_id = Project.where(id: ids).index_by(&:id)
      ids.filter_map { |project_id| projects_by_id[project_id] }
    end

    def applies_to_project?(target_project)
      project_obj = target_project.is_a?(Project) ? target_project : Project.find_by(id: target_project)
      return false unless project_obj
      return true if project_obj.id == project_id
      return false unless project_in_owner_tree?(project_obj)

      ids = selected_applied_subproject_ids
      ids.empty? || ids.include?(project_obj.id)
    end

    def recalculate_bonus_spent_hours!
      ordered_bonuses = bonuses.order(awarded_on: :asc, id: :asc).to_a
      entries = time_entries_for_recalculation.order(spent_on: :asc, id: :asc)
      spent_by_bonus = Hash.new(0.0)
      debt_hours = 0.0
      uncovered_hours = 0.0
      negative_hours = 0.0
      linked_entries = 0
      current_bonus_index = 0

      entries.each do |entry|
        entry_imputable = imputable_time_entry?(entry)
        next unless entry_imputable

        hours_left = entry.hours.to_f
        next if hours_left <= 0

        entry_date = entry.spent_on || entry.created_on&.to_date || Date.current

        # Activate bonuses available at entry date and use them first to cover prior debt.
        loop do
          bonus = ordered_bonuses[current_bonus_index]
          break unless bonus
          break if bonus.awarded_on > entry_date

          bonus_capacity = bonus.hours_total.to_f - spent_by_bonus[bonus.id]
          if bonus_capacity <= 0
            current_bonus_index += 1
            next
          end

          debt_allocation = [debt_hours, bonus_capacity].min
          if debt_allocation.positive?
            spent_by_bonus[bonus.id] += debt_allocation
            debt_hours -= debt_allocation
          end
          break
        end

        while hours_left.positive?
          bonus = ordered_bonuses[current_bonus_index]
          break unless bonus
          break if bonus.awarded_on > entry_date

          bonus_capacity = bonus.hours_total.to_f - spent_by_bonus[bonus.id]
          if bonus_capacity <= 0
            current_bonus_index += 1
            next
          end

          allocated = [hours_left, bonus_capacity].min
          spent_by_bonus[bonus.id] += allocated
          hours_left -= allocated
        end

        debt_hours += hours_left if hours_left.positive?

        # Link subtree entries even if they currently produce negative balance.
        if entry.contract_id.nil?
          entry.update_column(:contract_id, id)
          linked_entries += 1
        end
      end

      # Future bonuses (including newly added ones) first absorb prior debt.
      ordered_bonuses.each do |bonus|
        next unless debt_hours.positive?

        bonus_capacity = bonus.hours_total.to_f - spent_by_bonus[bonus.id]
        next if bonus_capacity <= 0

        debt_allocation = [debt_hours, bonus_capacity].min
        spent_by_bonus[bonus.id] += debt_allocation
        debt_hours -= debt_allocation
      end

      # If there is still debt, keep it as negative on the latest bonus line.
      if debt_hours.positive?
        if ordered_bonuses.any?
          last_bonus = ordered_bonuses.last
          spent_by_bonus[last_bonus.id] += debt_hours
          negative_hours = debt_hours
          debt_hours = 0.0
        else
          uncovered_hours = debt_hours
        end
      end

      transaction do
        ordered_bonuses.each do |bonus|
          bonus.update_columns(
            hours_spent_cache: spent_by_bonus[bonus.id].round(2),
            updated_at: Time.current
          )
        end
      end

      {
        allocated_hours: spent_by_bonus.values.sum.round(2),
        uncovered_hours: uncovered_hours.round(2),
        negative_hours: negative_hours.round(2),
        linked_entries: linked_entries
      }
    end

    private

    def time_entries_for_recalculation
      first_bonus_date = bonuses.minimum(:awarded_on)
      return TimeEntry.none unless first_bonus_date

      subtree_ids = applicable_project_ids
      TimeEntry.where(
        "contract_id = :contract_id OR (contract_id IS NULL AND project_id IN (:project_ids))",
        contract_id: id,
        project_ids: subtree_ids
      ).where('spent_on >= ?', first_bonus_date)
    end

    def project_tree_ids
      return [project_id] unless project.respond_to?(:self_and_descendants)

      project.self_and_descendants.pluck(:id)
    end

    def applicable_project_ids
      explicit_ids = selected_applied_subproject_ids
      ids = explicit_ids.empty? ? project_tree_ids : [project_id] + explicit_ids
      ids.map(&:to_i).uniq
    end

    def bonus_rows_cached?
      ordered_bonuses = bonuses.order(awarded_on: :asc, id: :asc)
      ordered_bonuses.where.not(hours_spent_cache: nil).any?
    end

    def bonus_rows_from_cache
      bonuses.order(awarded_on: :asc, id: :asc).map do |bonus|
        total = bonus.hours_total.to_f
        consumed = bonus.hours_spent_cache.to_f
        remaining = total - consumed

        {
          bonus: bonus,
          consumed_hours: consumed,
          remaining_hours: remaining
        }
      end
    end

    def bonus_rows_fifo
      remaining_to_allocate = spent_hours_from_entries

      bonuses.order(awarded_on: :asc, id: :asc).map do |bonus|
        total = bonus.hours_total.to_f
        consumed = [total, [remaining_to_allocate, 0.0].max].min
        remaining = total - consumed
        remaining_to_allocate -= consumed

        {
          bonus: bonus,
          consumed_hours: consumed,
          remaining_hours: remaining
        }
      end
    end

    def spent_hours_from_entries
      time_entries_for_recalculation.includes(:issue).sum do |entry|
        imputable_time_entry?(entry) ? entry.hours.to_f : 0.0
      end
    end

    def validate_imputation_custom_field
      return if imputation_custom_field_id.blank?

      custom_field = IssueCustomField.find_by(id: imputation_custom_field_id)
      return if custom_field&.field_format == 'bool'

      errors.add(:imputation_custom_field_id, :invalid)
    end

    def validate_imputation_versions
      version_ids = selected_version_ids
      return if version_ids.empty?

      existing_ids = Version.where(id: version_ids).pluck(:id)
      return if (version_ids - existing_ids).empty?

      errors.add(:imputation_version_ids, :invalid)
    end

    def validate_applied_subprojects
      ids = selected_applied_subproject_ids
      return if ids.empty?
      return if project_id.blank?

      valid_ids = Project.where(id: ids).pluck(:id)
      if (ids - valid_ids).any?
        errors.add(:applied_subproject_ids, :invalid)
        return
      end

      invalid_scope = ids.reject { |subproject_id| project_in_owner_tree?(Project.find_by(id: subproject_id)) }
      errors.add(:applied_subproject_ids, :invalid) if invalid_scope.any?
    end

    def issue_version_allowed?(issue)
      version_ids = selected_version_ids
      return true if version_ids.empty?
      return false unless issue

      version_ids.include?(issue.fixed_version_id.to_i)
    end

    def courtesy_time_entry?(entry)
      return false if imputation_custom_field_id.blank?

      source_project = entry.issue&.project || entry.project
      return false unless applies_to_project?(source_project)
      return false unless entry.spent_on && started_on && entry.spent_on >= started_on
      return false unless entry.issue
      return false if entry.contract_id == id

      issue_value = entry.issue.custom_field_value(imputation_custom_field_id)
      !truthy_custom_value?(issue_value)
    end

    def issue_has_custom_field?(issue, custom_field_id)
      issue.custom_field_values.any? { |cfv| cfv.custom_field_id.to_i == custom_field_id.to_i }
    end

    def normalize_version_ids(value)
      Array(value)
        .flat_map { |item| item.to_s.split(',') }
        .map(&:strip)
        .reject(&:blank?)
        .map(&:to_i)
        .uniq
    end

    def normalize_project_ids(value)
      normalize_version_ids(value)
    end

    def courtesy_candidate_entries
      TimeEntry.where(project_id: applicable_project_ids)
               .where('spent_on >= ?', started_on)
               .where.not(issue_id: nil)
               .includes(:project, issue: :custom_values)
               .order(spent_on: :asc, id: :asc)
    end

    def report_candidate_entries
      return TimeEntry.none unless started_on

      TimeEntry.where(project_id: applicable_project_ids)
               .where('spent_on >= ?', started_on)
               .where.not(issue_id: nil)
               .includes(:project, issue: :fixed_version)
               .order(spent_on: :asc, id: :asc)
    end

    def project_in_owner_tree?(candidate_project)
      return false unless candidate_project
      return true if candidate_project.id == project_id

      current = candidate_project
      while current
        return true if current.id == project_id

        current = current.parent
      end

      false
    end

    def read_optional_attribute(name)
      if has_attribute?(name)
        self[name]
      else
        instance_variable_get("@#{name}")
      end
    end

    def write_optional_attribute(name, value)
      if has_attribute?(name)
        self[name] = value
      else
        instance_variable_set("@#{name}", value)
      end
    end

    def truthy_custom_value?(value)
      raw = value.respond_to?(:value) ? value.value : value
      return raw if raw == true || raw == false

      %w[1 true t yes y on].include?(raw.to_s.strip.downcase)
    end
  end
end
