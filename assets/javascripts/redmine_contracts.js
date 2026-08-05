function initializeRedmineContractsBonusForm() {
  var toggle = document.getElementById('toggle-new-contract-bonus-form');
  var formBox = document.getElementById('new-contract-bonus-form');

  if (!toggle || !formBox || formBox.dataset.redmineContractsInitialized === 'true') {
    return;
  }

  formBox.dataset.redmineContractsInitialized = 'true';
  formBox.classList.remove('contract-bonus-form--collapsed');
  formBox.style.display = window.location.hash === '#new-contract-bonus-form' ? '' : 'none';

  var cancel = document.getElementById('cancel-new-contract-bonus-form');
  var continuePrevious = document.getElementById('continue_previous_bonus');
  var awardedOnWrapper = document.getElementById('contract_bonus_awarded_on_wrapper');
  var awardedOnInput = document.getElementById('contract_bonus_awarded_on');
  var bonusNameInput = document.getElementById('contract_bonus_name');
  var bonusHoursInput = document.getElementById('contract_bonus_hours_total');
  var summary = document.getElementById('continuation-bonus-summary');
  var summaryOverflow = document.getElementById('continuation-bonus-overflow-hours');
  var summaryInitial = document.getElementById('continuation-bonus-initial-hours');
  var overflowHours = 0;
  var nextName = '';

  if (continuePrevious) {
    overflowHours = parseFloat(continuePrevious.dataset.previousOverflowHours || '0');
    nextName = continuePrevious.dataset.nextName || '';
  }

  function showForm(show) {
    formBox.style.display = show ? '' : 'none';
  }

  function parsedHours() {
    if (!bonusHoursInput) {
      return 0;
    }

    var normalized = (bonusHoursInput.value || '').replace(',', '.');
    var parsed = parseFloat(normalized);
    return isNaN(parsed) ? 0 : parsed;
  }

  function updateContinuationSummary(enabled) {
    if (!summary || !summaryOverflow || !summaryInitial) {
      return;
    }

    if (!enabled || overflowHours <= 0) {
      summary.style.display = 'none';
      return;
    }

    var initialHours = parsedHours() - overflowHours;
    summaryOverflow.textContent = overflowHours.toFixed(2) + 'h';
    summaryInitial.textContent = initialHours.toFixed(2) + 'h';
    summary.style.display = '';
  }

  function updateContinuationForm() {
    if (!continuePrevious) {
      return;
    }

    var enabled = continuePrevious.checked;

    if (awardedOnWrapper) {
      awardedOnWrapper.style.display = enabled ? 'none' : '';
    }
    if (awardedOnInput) {
      awardedOnInput.required = !enabled;
    }
    if (bonusNameInput) {
      if (enabled && nextName.length > 0) {
        bonusNameInput.value = nextName;
      }
    }

    updateContinuationSummary(enabled);
  }

  toggle.addEventListener('click', function(event) {
    event.preventDefault();
    showForm(formBox.style.display === 'none');
  });

  if (cancel) {
    cancel.addEventListener('click', function(event) {
      event.preventDefault();
      showForm(false);
    });
  }

  if (continuePrevious) {
    continuePrevious.addEventListener('change', updateContinuationForm);

    if (bonusHoursInput) {
      bonusHoursInput.addEventListener('input', function() {
        updateContinuationSummary(continuePrevious.checked);
      });
    }

    updateContinuationForm();
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initializeRedmineContractsBonusForm);
} else {
  initializeRedmineContractsBonusForm();
}
