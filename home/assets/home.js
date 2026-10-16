/* Theme toggle for the Insights homepage. The page works without this file:
   it follows the visitor's OS setting. The choice is kept in localStorage,
   which can be blocked or empty, so every access is wrapped in try/catch. */
(function () {
  'use strict';

  var KEY = 'insights-theme';
  var root = document.documentElement;
  var query = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;

  root.classList.add('js');

  function readChoice() {
    try {
      var value = window.localStorage.getItem(KEY);
      return value === 'light' || value === 'dark' ? value : null;
    } catch (e) {
      return null;
    }
  }

  function saveChoice(value) {
    try {
      window.localStorage.setItem(KEY, value);
    } catch (e) {
      /* blocked storage: the choice lasts for this page view only */
    }
  }

  function effectiveTheme() {
    var set = root.getAttribute('data-theme');
    if (set === 'light' || set === 'dark') {
      return set;
    }
    return query && query.matches ? 'dark' : 'light';
  }

  var stored = readChoice();
  if (stored) {
    root.setAttribute('data-theme', stored);
  }

  function refresh(button) {
    var next = effectiveTheme() === 'dark' ? 'light' : 'dark';
    button.querySelector('.theme-toggle-label').textContent = 'Switch to ' + next + ' theme';
    button.querySelector('.icon-moon').hidden = next !== 'dark';
    button.querySelector('.icon-sun').hidden = next !== 'light';
  }

  document.addEventListener('DOMContentLoaded', function () {
    var button = document.getElementById('theme-toggle');
    if (!button) {
      return;
    }
    refresh(button);
    button.addEventListener('click', function () {
      var next = effectiveTheme() === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      saveChoice(next);
      refresh(button);
    });
    if (query && query.addEventListener) {
      query.addEventListener('change', function () {
        refresh(button);
      });
    }
  });
})();
