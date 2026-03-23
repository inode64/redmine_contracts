# frozen_string_literal: true

module RedmineContracts
  class ContractsController < ApplicationController
    before_action :find_project
    before_action :find_contract, only: %i[show report edit update recalculate]
    before_action :ensure_manageable_contract, only: %i[edit update recalculate]
    before_action :load_boolean_issue_custom_fields, only: %i[new create edit update]
    before_action :load_available_versions, only: %i[new create edit update]
    before_action :load_available_subprojects, only: %i[new create edit update]
    before_action :authorize

    helper :sort
    helper :custom_fields

    def index
      @contracts = RedmineContracts::Contract.visible_from_project(@project)
    end

    def show
      @contract_inherited = @contract.project_id != @project.id
      @can_manage_contract = User.current.allowed_to?(:manage_redmine_contracts, @project) && !@contract_inherited
      @bonus_rows = @contract.bonus_rows
      @courtesy_rows = @contract.courtesy_rows
      @courtesy_hours = @courtesy_rows.sum { |row| row[:hours].to_f }
      @bonus = RedmineContracts::ContractBonus.new(awarded_on: Date.current)
    end

    def report
      @group_by = params[:group_by].to_s
      @group_by = 'none' unless %w[none week month].include?(@group_by)
      @include_comments = ActiveModel::Type::Boolean.new.cast(params[:include_comments])

      @report_rows = @contract.report_rows
      @grouped_report_rows = grouped_report_rows(@report_rows, @group_by)
    end

    def new
      @contract = RedmineContracts::Contract.new(project: @project, started_on: Date.current, status: 'active')
    end

    def create
      @contract = RedmineContracts::Contract.new(contract_params.merge(project: @project))
      @contract.status = 'active' if @contract.status.blank?

      if @contract.save
        flash[:notice] = l(:notice_successful_create)
        redirect_to controller: 'redmine_contracts/contracts', action: 'show', project_id: @project, id: @contract
      else
        render action: 'new'
      end
    end

    def edit; end

    def update
      if @contract.update(contract_params)
        flash[:notice] = l(:notice_successful_update)
        redirect_to controller: 'redmine_contracts/contracts', action: 'show', project_id: @project, id: @contract
      else
        render action: 'edit'
      end
    end

    def recalculate
      result = @contract.recalculate_bonus_spent_hours!
      flash[:notice] = l(
        :notice_redmine_contract_recalculated,
        allocated: format('%.2f', result[:allocated_hours])
      )
      if result[:linked_entries].positive?
        flash[:notice] = "#{flash[:notice]} #{l(:notice_redmine_contract_entries_linked, count: result[:linked_entries])}"
      end

      if result[:uncovered_hours].positive?
        flash[:warning] = l(
          :warning_redmine_contract_uncovered_hours,
          hours: format('%.2f', result[:uncovered_hours])
        )
      end
      if result[:negative_hours].positive?
        flash[:warning] = [
          flash[:warning],
          l(:warning_redmine_contract_negative_balance, hours: format('%.2f', result[:negative_hours]))
        ].compact.join(' ')
      end

      redirect_to controller: 'redmine_contracts/contracts', action: 'show', project_id: @project, id: @contract
    end

    private

    def find_project
      @project = Project.find(params[:project_id])
    end

    def find_contract
      lineage_ids = RedmineContracts::Contract.project_lineage_ids(@project)
      @contract = RedmineContracts::Contract.find_by!(id: params[:id], project_id: lineage_ids)
      render_404 unless @contract.applies_to_project?(@project)
    end

    def ensure_manageable_contract
      render_404 unless @contract.project_id == @project.id
    end

    def contract_params
      payload = params[:contract] || params[:redmine_contracts_contract]
      raise ActionController::ParameterMissing, :contract if payload.blank?

      payload.permit(
        :name,
        :started_on,
        :status,
        :notes,
        :imputation_custom_field_id,
        imputation_version_ids: [],
        applied_subproject_ids: []
      )
    end

    def load_boolean_issue_custom_fields
      @boolean_issue_custom_fields = IssueCustomField.where(field_format: 'bool').order(:name)
    end

    def load_available_versions
      lineage_ids = RedmineContracts::Contract.project_lineage_ids(@project)
      descendant_ids = if @project.respond_to?(:self_and_descendants)
                         @project.self_and_descendants.pluck(:id)
                       else
                         [@project.id]
                       end
      project_ids = (lineage_ids + descendant_ids).uniq
      @available_versions = Version.where(project_id: project_ids).order(:name)
    end

    def load_available_subprojects
      @available_subprojects = if @project.respond_to?(:descendants)
                                 @project.descendants.order(:name)
                               else
                                 []
                               end
    end

    def grouped_report_rows(rows, group_by)
      return [] if rows.empty?
      return [{ label: l(:label_redmine_contract_group_none), rows: rows, total_hours: rows.sum { |row| row[:hours].to_f } }] if group_by == 'none'

      grouped = rows.group_by do |row|
        date = row[:date]
        if group_by == 'week'
          [date.cwyear, date.cweek]
        else
          [date.year, date.month]
        end
      end

      grouped.sort_by { |key, _| key }.map do |key, grouped_rows|
        label = if group_by == 'week'
                  week_label(key)
                else
                  month_label(key)
                end
        { label: label, rows: grouped_rows, total_hours: grouped_rows.sum { |row| row[:hours].to_f } }
      end
    end

    def week_label(key)
      year, week = key
      week_start = Date.commercial(year, week, 1)
      week_end = Date.commercial(year, week, 7)
      "#{l(:label_redmine_contract_group_week)} #{format('%02d', week)} (#{format_date(week_start)} - #{format_date(week_end)})"
    end

    def month_label(key)
      year, month = key
      "#{l(:label_redmine_contract_group_month)} #{format('%02d', month)}/#{year}"
    end
  end
end
