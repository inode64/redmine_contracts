# frozen_string_literal: true

require_relative 'lib/redmine_contracts'

Redmine::Plugin.register :redmine_contracts do
  name 'Redmine Contracts'
  author 'INODE64 Sistemas'
  description 'Hour-bundle contracts with automatic consumption from issue time entries'
  version '0.1.0'
  author_url 'https://www.inode64.com'
  requires_redmine version_or_higher: '6.0.0'

  project_module :redmine_contracts do
    permission :view_redmine_contracts,
               { 'redmine_contracts/contracts' => %i[index show report update_category] },
               read: true
    permission :manage_redmine_contracts,
               {
                 'redmine_contracts/contracts' => %i[index show report new create edit update recalculate update_category],
                 'redmine_contracts/contract_bonuses' => %i[create edit update destroy]
               },
               require: :member
  end

  menu :project_menu,
       :redmine_contracts,
       { controller: 'redmine_contracts/contracts', action: 'index' },
       caption: :label_redmine_contracts,
       param: :project_id,
       after: :activity
end

Rails.configuration.to_prepare do
  RedmineContracts::Patches.apply
end
