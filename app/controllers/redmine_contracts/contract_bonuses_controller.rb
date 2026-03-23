# frozen_string_literal: true

module RedmineContracts
  class ContractBonusesController < ApplicationController
    before_action :find_project
    before_action :find_contract
    before_action :find_bonus, only: %i[edit update destroy]
    before_action :authorize

    def create
      @bonus = @contract.bonuses.build(contract_bonus_params)

      if @bonus.save
        flash[:notice] = l(:notice_successful_create)
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
  end
end
