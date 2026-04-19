# frozen_string_literal: true

module RedmineContracts
  class ContractsController < ApplicationController
    before_action :find_project
    before_action :find_contract, only: %i[show report edit update recalculate]
    before_action :ensure_manageable_contract, only: %i[edit update recalculate]
    before_action :load_boolean_issue_custom_fields, only: %i[new create edit update]
    before_action :load_issue_custom_fields, only: %i[new create edit update]
    before_action :load_available_versions, only: %i[new create edit update]
    before_action :load_available_subprojects, only: %i[new create edit update]
    before_action :load_report_visible_field_options, only: %i[new create edit update]
    before_action :authorize

    helper :sort
    helper :custom_fields
    helper_method :report_column_label, :report_column_display_value

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
      @time_group_by, @detail_group_by = selected_report_grouping
      @include_comments = ActiveModel::Type::Boolean.new.cast(params[:include_comments])
      @available_report_bonuses = @contract.bonuses.order(awarded_on: :asc, id: :asc).to_a
      @selected_report_bonus_id = selected_report_bonus_id(@available_report_bonuses)

      @report_rows = @contract.report_rows(bonus_id: @selected_report_bonus_id)
      @report_column_keys = selected_report_column_keys(@include_comments)
      @grouped_report_rows = grouped_report_rows(@report_rows, @time_group_by, @detail_group_by)

      respond_to do |format|
        format.html
        format.csv do
          send_data(
            contract_report_to_csv(@grouped_report_rows, @report_column_keys),
            type: 'text/csv; header=present',
            filename: "#{contract_report_export_filename}.csv"
          )
        end
        format.pdf do
          send_data(
            contract_report_to_pdf(@grouped_report_rows, @report_column_keys),
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
        :report_category_custom_field_id,
        imputation_version_ids: [],
        applied_subproject_ids: [],
        report_visible_field_keys: []
      )
    end

    def load_boolean_issue_custom_fields
      @boolean_issue_custom_fields = IssueCustomField.where(field_format: 'bool').order(:name)
    end

    def load_issue_custom_fields
      @issue_custom_fields = IssueCustomField.order(:name, :id)
    end

    def load_available_versions
      project_ids = (RedmineContracts::Contract.project_lineage_ids(@project) +
                     @project.self_and_descendants.pluck(:id)).uniq
      @available_versions = Version.where(project_id: project_ids).order(:name)
    end

    def load_available_subprojects
      @available_subprojects = @project.descendants.order(:name)
    end

    def load_report_visible_field_options
      fixed_options = RedmineContracts::Contract::AVAILABLE_REPORT_FIELD_KEYS.map do |key|
        [report_column_label(key), key]
      end
      issue_custom_options = available_issue_report_custom_fields.map do |custom_field|
        key = RedmineContracts::Contract.custom_report_field_key('issue', custom_field.id)
        [report_column_label(key), key]
      end
      time_entry_custom_options = available_time_entry_report_custom_fields.map do |custom_field|
        key = RedmineContracts::Contract.custom_report_field_key('time_entry', custom_field.id)
        [report_column_label(key), key]
      end

      @available_report_visible_field_options = fixed_options + issue_custom_options + time_entry_custom_options
    end

    def grouped_report_rows(rows, time_group_by, detail_group_by)
      return [] if rows.empty?
      grouped_by_time = if time_group_by == 'none'
                          [[nil, rows]]
                        else
                          rows.group_by { |row| time_group_key(row, time_group_by) }
                              .sort_by { |key, _| key }
                        end

      grouped_by_time.map do |time_key, grouped_rows|
        {
          label: time_group_label(time_group_by, time_key),
          show_label: time_group_by != 'none',
          total_hours: grouped_rows.sum { |row| row[:hours].to_f },
          subgroups: grouped_report_subgroups(grouped_rows, detail_group_by)
        }
      end
    end

    def grouped_report_subgroups(rows, detail_group_by)
      if detail_group_by == 'none'
        return [
          {
            label: nil,
            show_label: false,
            rows: rows,
            total_hours: rows.sum { |row| row[:hours].to_f }
          }
        ]
      end

      grouped = rows.group_by { |row| detail_group_key(row, detail_group_by) }
      grouped.sort_by { |key, _| key.to_s.downcase }.map do |key, grouped_rows|
        {
          label: detail_group_label(detail_group_by, key),
          show_label: true,
          rows: grouped_rows,
          total_hours: grouped_rows.sum { |row| row[:hours].to_f }
        }
      end
    end

    def time_group_key(row, time_group_by)
      date = row[:date] || Date.current
      return [date.year, date.month] if time_group_by == 'month'

      [date.cwyear, date.cweek]
    end

    def detail_group_key(row, detail_group_by)
      return row[:project]&.name.to_s.presence || '-' if detail_group_by == 'project'
      return report_category_value_for_group(row) if detail_group_by == 'category'

      row[:bonus_label].presence || '-'
    end

    def time_group_label(time_group_by, key)
      return nil if time_group_by == 'none'

      if time_group_by == 'week'
        week_label(key)
      else
        month_label(key)
      end
    end

    def detail_group_label(detail_group_by, key)
      if detail_group_by == 'project'
        "#{l(:label_redmine_contract_group_project)}: #{key}"
      elsif detail_group_by == 'category'
        "#{l(:label_redmine_contract_group_category)}: #{key}"
      else
        "#{l(:label_redmine_contract_group_bonus)}: #{key}"
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

    def contract_report_to_csv(grouped_rows, column_keys)
      Redmine::Export::CSV.generate(
        encoding: params[:encoding],
        field_separator: params[:field_separator]
      ) do |csv|
        csv << column_keys.map { |key| report_column_label(key) }
        hours_column_index = column_keys.index('hours')

        grouped_rows.each do |group|
          if group[:show_label]
            group_row = Array.new(column_keys.length, '')
            if hours_column_index
              group_row[0] = group[:label]
              group_row[hours_column_index] = group[:total_hours].to_f
            else
              group_row[0] = "#{group[:label]} (#{l(:label_redmine_contract_total_hours)}: #{format('%.2f', group[:total_hours].to_f)})"
            end
            csv << group_row
          end

          group[:subgroups].each do |subgroup|
            if subgroup[:show_label]
              subgroup_row = Array.new(column_keys.length, '')
              if hours_column_index
                subgroup_row[0] = "  #{subgroup[:label]}"
                subgroup_row[hours_column_index] = subgroup[:total_hours].to_f
              else
                subgroup_row[0] = "  #{subgroup[:label]} (#{l(:label_redmine_contract_total_hours)}: #{format('%.2f', subgroup[:total_hours].to_f)})"
              end
              csv << subgroup_row
            end

            subgroup[:rows].each do |row|
              csv << column_keys.map { |key| report_column_csv_value(row, key) }
            end
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

    def selected_report_grouping
      time_group_by = params[:time_group_by].to_s
      detail_group_by = params[:detail_group_by].to_s
      legacy_group_by = params[:group_by].to_s

      if time_group_by.blank? && detail_group_by.blank?
        case legacy_group_by
        when 'week', 'month'
          time_group_by = legacy_group_by
          detail_group_by = 'bonus'
        when 'bonus'
          time_group_by = 'none'
          detail_group_by = 'bonus'
        else
          time_group_by = 'week'
          detail_group_by = 'bonus'
        end
      end

      time_group_by = 'week' unless %w[none week month].include?(time_group_by)
      detail_group_by = 'bonus' unless %w[none bonus project category].include?(detail_group_by)
      [time_group_by, detail_group_by]
    end

    def selected_report_column_keys(include_comments)
      keys = @contract.selected_report_visible_field_keys.dup
      keys << 'comments' if include_comments
      keys
    end

    def contract_report_to_pdf(grouped_rows, column_keys)
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
      headers = column_keys.map { |key| report_column_label(key) }
      widths = column_keys.map { |key| report_column_pdf_width(key) }
      max_lengths = column_keys.map { |key| report_column_pdf_max_length(key) }
      table_width = widths.sum

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
        if group[:show_label]
          if pdf.get_y + row_height > page_height - bottom_margin
            pdf.add_page('L')
            draw_table_header.call
          end

          pdf.SetFontStyle('B', 8)
          group_label = "#{group[:label]} (#{l(:label_redmine_contract_total_hours)}: #{format('%.2f', group[:total_hours].to_f)})"
          pdf.RDMCell(table_width, row_height, truncate_for_pdf(group_label, 160), 1, 1, 'L')
        end

        group[:subgroups].each do |subgroup|
          if subgroup[:show_label]
            if pdf.get_y + row_height > page_height - bottom_margin
              pdf.add_page('L')
              draw_table_header.call
            end

            pdf.SetFontStyle('B', 8)
            subgroup_label = "#{subgroup[:label]} (#{l(:label_redmine_contract_total_hours)}: #{format('%.2f', subgroup[:total_hours].to_f)})"
            pdf.RDMCell(table_width, row_height, truncate_for_pdf(subgroup_label, 160), 1, 1, 'L')
          end

          subgroup[:rows].each do |row|
            if pdf.get_y + row_height > page_height - bottom_margin
              pdf.add_page('L')
              draw_table_header.call
            end

            values = column_keys.map { |key| report_column_display_value(row, key) }

            pdf.SetFontStyle('', 8)
            values.each_with_index do |value, index|
              align = report_column_align(column_keys[index])
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
      end

      pdf.output
    end

    def report_column_label(key)
      case key.to_s
      when 'date' then l(:field_date)
      when 'project' then l(:field_project)
      when 'issue' then l(:field_issue)
      when 'version' then l(:field_fixed_version)
      when 'bonus' then l(:label_redmine_contract_bonus_name)
      when 'hours' then l(:field_hours)
      when 'comments' then l(:field_comments)
      else
        custom_field_info = RedmineContracts::Contract.parse_custom_report_field_key(key)
        return key.to_s.humanize unless custom_field_info

        custom_field = find_custom_report_field(custom_field_info[:scope], custom_field_info[:id])
        custom_field&.name || "CF ##{custom_field_info[:id]}"
      end
    end

    def report_column_display_value(row, key)
      issue = row[:issue]

      case key.to_s
      when 'date'
        row[:date] ? format_date(row[:date]) : '-'
      when 'project'
        row[:project]&.name || '-'
      when 'issue'
        issue ? "##{issue.id} #{issue.subject}" : '-'
      when 'version'
        row[:version]&.name || '-'
      when 'bonus'
        row[:bonus_label].presence || '-'
      when 'hours'
        format('%.2f', row[:hours].to_f)
      when 'comments'
        row[:time_entry]&.comments.presence || '-'
      else
        custom_report_field_value(row, key).presence || '-'
      end
    end

    def report_column_csv_value(row, key)
      case key.to_s
      when 'date' then row[:date] ? format_date(row[:date]) : ''
      when 'project' then row[:project]&.name.to_s
      when 'issue'
        issue = row[:issue]
        issue ? "##{issue.id} #{issue.subject}" : ''
      when 'version' then row[:version]&.name.to_s
      when 'bonus' then row[:bonus_label].to_s
      when 'hours' then row[:hours].to_f
      when 'comments' then row[:time_entry]&.comments.to_s
      else custom_report_field_value(row, key).to_s
      end
    end

    def report_column_pdf_width(key)
      case key.to_s
      when 'date' then 20
      when 'project' then 34
      when 'issue' then 58
      when 'version' then 30
      when 'bonus' then 45
      when 'hours' then 16
      when 'comments' then 74
      else 42
      end
    end

    def report_column_pdf_max_length(key)
      case key.to_s
      when 'date' then 14
      when 'project' then 22
      when 'issue' then 36
      when 'version' then 18
      when 'bonus' then 30
      when 'hours' then 10
      when 'comments' then 56
      else 28
      end
    end

    def report_column_align(key)
      key.to_s == 'hours' ? 'R' : 'L'
    end

    def available_issue_report_custom_fields
      @available_issue_report_custom_fields ||= IssueCustomField.order(:name, :id).to_a
    end

    def available_time_entry_report_custom_fields
      @available_time_entry_report_custom_fields ||= if defined?(TimeEntryCustomField)
                                                       TimeEntryCustomField.order(:name, :id).to_a
                                                     else
                                                       []
                                                     end
    end

    def issue_report_custom_fields_by_id
      @issue_report_custom_fields_by_id ||= available_issue_report_custom_fields.index_by(&:id)
    end

    def time_entry_report_custom_fields_by_id
      @time_entry_report_custom_fields_by_id ||= available_time_entry_report_custom_fields.index_by(&:id)
    end

    def find_custom_report_field(scope, custom_field_id)
      if scope == 'issue'
        issue_report_custom_fields_by_id[custom_field_id]
      else
        time_entry_report_custom_fields_by_id[custom_field_id]
      end
    end

    def custom_report_field_value(row, key)
      custom_field_info = RedmineContracts::Contract.parse_custom_report_field_key(key)
      return '' unless custom_field_info

      source = custom_field_info[:scope] == 'issue' ? row[:issue] : row[:time_entry]
      return '' unless source

      custom_field = find_custom_report_field(custom_field_info[:scope], custom_field_info[:id])
      return '' unless custom_field

      view_context.format_value(source.custom_field_value(custom_field.id), custom_field).to_s
    end

    def report_category_value_for_group(row)
      custom_field = @contract.report_category_custom_field
      return '-' unless custom_field

      issue = row[:issue]
      return '-' unless issue

      formatted = view_context.format_value(issue.custom_field_value(custom_field.id), custom_field).to_s.strip
      formatted.presence || '-'
    end

    def truncate_for_pdf(value, max_length)
      text = value.to_s
      return text if text.length <= max_length

      "#{text[0, max_length - 3]}..."
    end
  end
end
