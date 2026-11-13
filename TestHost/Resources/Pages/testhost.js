// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared script of the local test pages (02-platform.md 13.2, QA-R10). No network: every page is loaded from
// file:// by the TestHost WKWebView or by a browser on the self-hosted runner.
// - Mirroring: every element with data-testhost-field posts its value to the TestHost message handler (when
//   present) and to an optional element with data-testhost-echo, so AX and WebDriver readbacks agree.
// - Inline completion and column autocomplete follow the same rules as TestHost/Sources/NativeFields.swift.
(function () {
  "use strict";

  function valueOf(element) {
    if (element.isContentEditable) {
      return element.innerText.replace(/\n$/, "");
    }
    return element.value;
  }

  function post(field, value) {
    var handlers = window.webkit && window.webkit.messageHandlers;
    if (handlers && handlers.testhost) {
      handlers.testhost.postMessage({ field: field, value: value });
    }
    var echo = document.querySelector('[data-testhost-echo="' + field + '"]');
    if (echo) {
      echo.textContent = value;
    }
  }

  function mirror(element) {
    post(element.dataset.testhostField, valueOf(element));
  }

  function fieldElement(field) {
    return document.querySelector('[data-testhost-field="' + field + '"]');
  }

  // Lowercase; with diacritics also stripped (đ/Đ have no Unicode decomposition, so map them explicitly).
  function fold(text, diacritics) {
    var lowered = text.toLowerCase();
    if (!diacritics) {
      return lowered;
    }
    return lowered.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/đ/g, "d");
  }

  function remainder(typed, suggestions, diacritics) {
    var key = fold(typed, diacritics);
    if (key.length === 0) {
      return null;
    }
    for (var i = 0; i < suggestions.length; i += 1) {
      var folded = fold(suggestions[i], diacritics);
      if (folded.length > key.length && folded.indexOf(key) === 0) {
        return Array.from(suggestions[i]).slice(Array.from(typed).length).join("");
      }
    }
    return null;
  }

  // After an insertion at the end, append and select the remainder of the first matching suggestion. A
  // backspace then deletes only the selection, which is the behaviour naive injection gets wrong.
  function attachCompletion(input, suggestions, diacritics) {
    input.addEventListener("input", function (event) {
      var text = input.value;
      var inserting = typeof event.inputType === "string" && event.inputType.indexOf("insert") === 0;
      var atEnd = input.selectionStart === text.length && input.selectionEnd === text.length;
      var rest = inserting && atEnd ? remainder(text, suggestions, diacritics) : null;
      if (rest) {
        input.value = text + rest;
        input.setSelectionRange(text.length, input.value.length);
      }
      mirror(input);
    });
  }

  function reset(field) {
    var element = fieldElement(field);
    if (!element) {
      return;
    }
    if (element.isContentEditable) {
      element.textContent = "";
    } else {
      element.value = "";
    }
    mirror(element);
  }

  function focus(field) {
    var element = fieldElement(field);
    if (element) {
      element.focus();
    }
  }

  document.addEventListener("input", function (event) {
    var element = event.target.closest && event.target.closest("[data-testhost-field]");
    if (element && !element.hasAttribute("data-testhost-completions")) {
      mirror(element);
    }
  });

  document.addEventListener("DOMContentLoaded", function () {
    document.querySelectorAll("[data-testhost-completions]").forEach(function (input) {
      var suggestions = input.getAttribute("data-testhost-completions").split("|");
      attachCompletion(input, suggestions, input.hasAttribute("data-testhost-fold-diacritics"));
    });
    document.querySelectorAll("[data-testhost-field]").forEach(mirror);
    // "#focus=<element id>" focuses that element on load, so a browser scenario needs no AX or WebDriver to
    // put the caret in the field (setup value "{pages}/fields.html#focus=web-textarea").
    var match = /^#focus=([A-Za-z0-9_-]+)$/.exec(window.location.hash);
    var target = match && document.getElementById(match[1]);
    if (target) {
      target.focus();
    }
  });

  window.TestHost = { mirror: mirror, reset: reset, focus: focus, fold: fold, remainder: remainder,
    attachCompletion: attachCompletion };
})();
