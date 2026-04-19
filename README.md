# Redmine Contracts Plugin (Redmine 6.0+)

This plugin adds hour-bundle contracts to Redmine projects.

## Features

- Create contracts per project.
- Extend contracts by adding new hour bonuses.
- Edit and delete hour bonus lines.
- Track bonus rows with:
  - date
  - bonus name
  - invoice reference (free text)
  - total hours
  - spent hours
  - remaining hours
- Automatically consumes contract hours from issue time entries.
- Contracts are inherited by subprojects (fallback to parent chain).
- Manual button to recalculate spent hours by bonus date, including child projects.
- Recalculation supports negative balance and automatically readjusts when a new bonus is added.
- Optional boolean issue custom field per contract to decide if a time entry is imputable to bonuses.
- Optional multi-select issue versions per contract to impute only matching issue versions.
- Optional multi-select subprojects per contract to restrict where the contract applies.
- Courtesy hours view for non-billed entries (boolean field missing/false) from contract start date.
- Hours report by issue/project/version from contract start date with grouping by week or month.
- Contract-level selection of visible report fields (base fields + issue/time-entry custom fields).
- Frontend translations in English and Spanish.

## Data model

- `redmine_contracts`
- `redmine_contract_bonuses`
- `time_entries.contract_id` (automatic assignment to active contract)

## Install

1. Copy folder to Redmine plugins path:
   - `plugins/redmine_contracts`
2. Run migrations:
   - `bundle exec rake redmine:plugins:migrate NAME=redmine_contracts RAILS_ENV=production`
3. Restart Redmine.

## Usage

1. Open a project.
2. Go to **Hour contracts** tab.
3. Create a contract.
4. Add one or more hour bonuses.
5. Log time on project issues; hours are automatically consumed.

## Notes

- Bonus spent/remaining rows are shown using FIFO consumption by bonus date.
- Time entries are assigned to the most recent active project contract at creation time.
