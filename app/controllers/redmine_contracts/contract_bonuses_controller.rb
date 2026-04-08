# frozen_string_literal: true

module RedmineContracts
  class ContractBonusesController < ApplicationController
    before_action :find_project
    before_action :find_contract
    before_action :find_bonus, only: %i[edit update destroy]
    before_action :authorize

    def create
      previous_bonus = @contract.bonuses.order(awarded_on: :asc, id: :asc).last
      continuation_enabled = continue_previous_bonus?

      if continuation_enabled && previous_bonus.blank?
        flash[:error] = l(:error_redmine_contract_bonus_previous_missing)
        return redirect_to(controller: 'redmine_contracts/contracts', action: 'show', project_id: @project, id: @contract)
      end

      previous_overflow_hours = continuation_enabled ? overflow_hours_for_bonus(previous_bonus) : 0.0
      @bonus = @contract.bonuses.build(contract_bonus_params)

      if continuation_enabled && previous_bonus
        @bonus.name = RedmineContracts::ContractBonus.next_correlative_name(previous_bonus.name)
        @bonus.awarded_on = [Date.current, previous_bonus.awarded_on].max
      end

      if @bonus.save
        notice = l(:notice_successful_create)
        if continuation_enabled
          notice = [
            notice,
            l(
              :notice_redmine_contract_bonus_continued,
              overflow: format('%.2f', previous_overflow_hours.to_f)
            )
          ].join(' ')
        end
        flash[:notice] = notice
      else
        flash[:error] = @bonus.errors.full_messages.to_sentence
      end

      redirect_to controller: 'redmine_contracts/contracts', action: 'show', project_id: @project, id: @contract
    end

    def edit; end

    def update
      if @bonus.update(contract_bonus_params)
        flash[:notice] = l(:notice_successful_update)
        redirect_to controller: 'redmine_contracts/contracts', action: 'show', project_id: @project, id: @contract
      else
        render action: 'edit'
      end
    end

    def destroy
      if @bonus.destroy
        flash[:notice] = l(:notice_successful_delete)
      else
        flash[:error] = @bonus.errors.full_messages.to_sentence
      end

      redirect_to controller: 'redmine_contracts/contracts', action: 'show', project_id: @project, id: @contract
    end

    private

    def find_project
      @project = Project.find(params[:project_id])
    end

    def find_contract
      @contract = RedmineContracts::Contract.find_by!(id: params[:contract_id], project_id: @project.id)
    end

    def find_bonus
      @bonus = @contract.bonuses.find(params[:id])
    end

    def contract_bonus_params
      payload = params[:contract_bonus] || params[:redmine_contracts_contract_bonus]
      raise ActionController::ParameterMissing, :contract_bonus if payload.blank?

      payload.permit(:awarded_on, :name, :invoice_reference, :hours_total)
    end

    def continue_previous_bonus?
      ActiveModel::Type::Boolean.new.cast(params[:continue_previous_bonus])
    end

    def overflow_hours_for_bonus(bonus)
      return 0.0 unless bonus

      row = @contract.bonus_rows.find { |item| item[:bonus].id == bonus.id }
      return 0.0 unless row

      remaining = row[:remaining_hours].to_f
      remaining.negative? ? remaining.abs : 0.0
    end
  end
end
