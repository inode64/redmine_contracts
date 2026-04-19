# frozen_string_literal: true

RedmineApp::Application.routes.draw do
  scope '/projects/:project_id/redmine_contracts', module: 'redmine_contracts', as: 'project_redmine_contracts' do
    resources :contracts, except: :destroy do
      get :report, on: :member
      post :recalculate, on: :member
      post :update_category, on: :member
      resources :contract_bonuses, path: 'bonuses', only: %i[create edit update destroy]
    end
  end
end
