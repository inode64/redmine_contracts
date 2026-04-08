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
      @previous_bonus = @bonus_rows.last&.dig(:bonus)
      @next_bonus_name = @previous_bonus ? RedmineContracts::ContractBonus.next_correlative_name(@previous_bonus.name) : nil
      @previous_bonus_overflow_hours = previous_bonus_overflow_hours
      @bonus = RedmineContracts::ContractBonus.new(awarded_on: Date.current)
    end

    def report
      @group_by = params[:group_by].to_s
      @group_by = 'none' unless %w[none week month].include?(@group_by)
      @include_comments = ActiveModel::Type::Boolean.new.cast(params[:include_comments])
      @available_report_bonuses = @contract.bonuses.order(awarded_on: :asc, id: :asc).to_a
      @selected_report_bonus_id = selected_report_bonus_id(@available_report_bonuses)

      @report_rows = @contract.report_rows(bonus_id: @selected_report_bonus_id)
      @grouped_report_rows = grouped_report_rows(@report_rows, @group_by)

      respond_to do |format|
        format.html
        format.csv do
          send_data(
            contract_report_to_csv(@grouped_report_rows, @group_by, @include_comments),
            type: 'text/csv; header=present',
            filename: "#{contract_report_export_filename}.csv"
          )
        end
        format.pdf do
          send_data(
            contract_report_to_pdf(@grouped_report_rows, @group_by, @include_comments),
            type: 'application/pdf',
            filename: "#{contract_report_export_filename}.pdf"
          )
        end
      end
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

    def contract_report_export_filename
      slug = @contract.name.to_s.parameterize
      slug = "contract-#{@contract.id}" if slug.blank?
      "#{slug}-hours-report-#{Date.current.strftime('%Y%m%d')}"
    end

    def contract_report_to_csv(grouped_rows, group_by, include_comments)
      Redmine::Export::CSV.generate(
        encoding: params[:encoding],
        field_separator: params[:field_separator]
      ) do |csv|
        headers = [
          l(:field_date),
          l(:field_project),
          l(:field_issue),
          l(:field_fixed_version),
          l(:label_redmine_contract_bonus_name),
          l(:field_hours)
        ]
        headers << l(:field_comments) if include_comments
        csv << headers

        grouped_rows.each do |group|
          if group_by != 'none'
            group_row = [group[:label], '', '', '', '', group[:total_hours].to_f]
            group_row << '' if include_comments
            csv << group_row
          end

          group[:rows].each do |row|
            issue = row[:issue]
            csv_row = [
              row[:date] ? format_date(row[:date]) : '',
              row[:project]&.name.to_s,
              issue ? "##{issue.id} #{issue.subject}" : '',
              row[:version]&.name.to_s,
              row[:bonus_label].to_s,
              row[:hours].to_f
            ]
            csv_row << row[:time_entry]&.comments.to_s if include_comments
            csv << csv_row
          end
        end
      end
    end

    def previous_bonus_overflow_hours
      row = @bonus_rows.last
      return 0.0 unless row

      remaining = row[:remaining_hours].to_f
      remaining.negative? ? remaining.abs : 0.0
    end

    def selected_report_bonus_id(available_bonuses)
      raw_bonus_id = params[:bonus_id].presence
      return nil unless raw_bonus_id

      bonus_id = raw_bonus_id.to_i
      return nil if bonus_id <= 0

      available_ids = available_bonuses.map(&:id)
      available_ids.include?(bonus_id) ? bonus_id : nil
    end

    def contract_report_to_pdf(grouped_rows, group_by, include_comments)
      pdf = Redmine::Export::PDF::ITCPDF.new(current_language, 'L')
      title = "#{@project} - #{l(:label_redmine_contract_hours_report)}: #{@contract.name}"
      pdf.set_title(title)
      pdf.alias_nb_pages
      pdf.footer_date = format_date(User.current.today)
      pdf.set_auto_page_break(false)
      pdf.add_page('L')

      page_height = pdf.get_page_height
      bottom_margin = pdf.get_footer_margin
      row_height = 6
      headers = [
        l(:field_date),
        l(:field_project),
        l(:field_issue),
        l(:field_fixed_version),
        l(:label_redmine_contract_bonus_name),
        l(:field_hours)
      ]
      widths = include_comments ? [20, 34, 58, 30, 45, 16, 74] : [24, 42, 80, 36, 62, 24]
      max_lengths = include_comments ? [14, 22, 36, 18, 30, 10, 56] : [16, 24, 45, 20, 42, 10]
      headers << l(:field_comments) if include_comments
      table_width = widths.sum
      hours_column_index = 5

      draw_table_header = lambda do
        pdf.SetFontStyle('B', 8)
        headers.each_with_index do |header, index|
          pdf.RDMCell(widths[index], row_height, header, 1, index == headers.length - 1 ? 1 : 0, 'L')
        end
      end

      pdf.SetFontStyle('B', 11)
      pdf.RDMCell(0, 8, title, 0, 1, 'L')
      pdf.SetFontStyle('', 9)
      pdf.RDMCell(0, 6, "#{l(:label_redmine_contract_report_from)}: #{format_date(@contract.started_on)}", 0, 1, 'L')
      pdf.ln(1)
      draw_table_header.call

      grouped_rows.each do |group|
        if group_by != 'none'
          if pdf.get_y + row_height > page_height - bottom_margin
            pdf.add_page('L')
            draw_table_header.call
          end

          pdf.SetFontStyle('B', 8)
          group_label = "#{group[:label]} (#{l(:label_redmine_contract_total_hours)}: #{format('%.2f', group[:total_hours].to_f)})"
          pdf.RDMCell(table_width, row_height, truncate_for_pdf(group_label, 160), 1, 1, 'L')
        end

        group[:rows].each do |row|
          if pdf.get_y + row_height > page_height - bottom_margin
            pdf.add_page('L')
            draw_table_header.call
          end

          issue = row[:issue]
          values = [
            row[:date] ? format_date(row[:date]) : '-',
            row[:project]&.name || '-',
            issue ? "##{issue.id} #{issue.subject}" : '-',
            row[:version]&.name || '-',
            row[:bonus_label].presence || '-',
            format('%.2f', row[:hours].to_f)
          ]
          values << (row[:time_entry]&.comments.presence || '-') if include_comments

          pdf.SetFontStyle('', 8)
          values.each_with_index do |value, index|
            align = index == hours_column_index ? 'R' : 'L'
            pdf.RDMCell(
              widths[index],
              row_height,
              truncate_for_pdf(value.to_s, max_lengths[index]),
              1,
              index == values.length - 1 ? 1 : 0,
              align
            )
          end
        end
      end

      pdf.output
    end

    def truncate_for_pdf(value, max_length)
      text = value.to_s
      return text if text.length <= max_length

      "#{text[0, max_length - 3]}..."
    end
  end
end
