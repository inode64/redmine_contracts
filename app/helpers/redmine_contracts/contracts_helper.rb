# frozen_string_literal: true

module RedmineContracts
  module ContractsHelper
    def format_contract_hours(value) = format('%.2f', value.to_f)

    def contract_progress_percent(total_hours, spent_hours)
      total = total_hours.to_f
      spent = spent_hours.to_f
      return 0.0 if total <= 0

      raw = (spent / total) * 100.0
      [[raw, 0.0].max, 100.0].min.round(1)
    end

    def contract_progress_bar(total_hours, spent_hours)
      percent = contract_progress_percent(total_hours, spent_hours)
      color = if percent >= 100
                '#c62828'
              elsif percent >= 80
                '#ef6c00'
              else
                '#2e7d32'
              end

      content_tag(:div,
                  class: 'redmine-contract-progress',
                  style: 'position:relative;width:220px;height:18px;border-radius:9px;background:#e6e8eb;overflow:hidden;display:inline-block;vertical-align:middle;') do
        safe_join(
          [
            content_tag(:span, '',
                        style: "display:block;height:100%;width:#{percent}%;background:#{color};"),
            content_tag(:span,
                        "#{format('%.1f', percent)}%",
                        style: 'position:absolute;left:0;top:0;width:100%;height:100%;line-height:18px;text-align:center;font-size:11px;font-weight:600;color:#111;')
          ]
        )
      end
    end
  end
end
