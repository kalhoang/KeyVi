// SPDX-License-Identifier: GPL-3.0-or-later
// Copy and share buttons of the donate page (PRD-R59, design 7.5, plan Task 7): a classic deferred script on /ung-ho/
// and /en/donate/ only. The page is complete without it: the bank name, the account number and the share text are
// selectable text, and every button stays hidden. With it:
// - each <button data-copy="text" hidden> shows when the browser offers navigator.clipboard.writeText and copies its
//   text; the status line of its block ([data-copy-scope] [data-copy-status]) reads data-copied for a moment. When the
//   browser refuses, the value is selected instead, so Command+C copies it;
// - the <button data-share="text" hidden> shows only when navigator.share exists and opens the system share sheet with
//   the text; a share that fails for another reason than the visitor closing the sheet copies the text instead.
// Under the production CSP (design 4) it writes text with textContent only, never markup or style attributes.
// The functions are SiteCopy, on window and for CommonJS (site/test.mjs loads them with createRequire).
(function (root, factory) {
  "use strict";
  const copy = factory();
  if (typeof module === "object" && module !== null && module.exports) module.exports = copy;
  if (!root || !root.document) return;
  root.SiteCopy = copy;
  if (root.document.readyState === "loading") root.document.addEventListener("DOMContentLoaded", () => copy.boot(root), { once: true });
  else copy.boot(root);
})(typeof window === "undefined" ? null : window, function () {
  "use strict";

  // How long the status line says the text was copied, in ms.
  const STATUS_MS = 2500;

  function canCopy(win) {
    const clipboard = win.navigator && win.navigator.clipboard;
    return Boolean(clipboard) && typeof clipboard.writeText === "function";
  }

  function canShare(win) {
    return Boolean(win.navigator) && typeof win.navigator.share === "function";
  }

  function scopeOf(button) {
    return button.closest("[data-copy-scope]");
  }

  function confirmCopied(win, button) {
    const scope = scopeOf(button);
    const status = scope && scope.querySelector("[data-copy-status]");
    if (!status) return;
    status.textContent = status.getAttribute("data-copied") || "";
    win.setTimeout(() => {
      status.textContent = "";
    }, STATUS_MS);
  }

  /** The browser refused the copy: select the value on the page so the visitor can copy it by hand. */
  function selectValue(win, button, text) {
    const scope = scopeOf(button);
    const values = scope ? Array.from(scope.querySelectorAll("[data-copy-value]")) : [];
    const value = values.find((el) => el.textContent.trim() === text);
    const selection = typeof win.getSelection === "function" ? win.getSelection() : null;
    if (value && selection) selection.selectAllChildren(value);
  }

  function copyText(win, button, text) {
    return win.navigator.clipboard.writeText(text).then(
      () => confirmCopied(win, button),
      () => selectValue(win, button, text),
    );
  }

  function share(win, button, text) {
    return win.navigator.share({ text }).catch((error) => {
      // Closing the share sheet is the visitor's choice; any other failure falls back to copying the same text.
      if (error && error.name === "AbortError") return undefined;
      return canCopy(win) ? copyText(win, button, text) : selectValue(win, button, text);
    });
  }

  function boot(win) {
    const doc = win.document;
    if (canCopy(win)) {
      Array.from(doc.querySelectorAll("[data-copy]")).forEach((button) => {
        button.hidden = false;
        button.addEventListener("click", () => copyText(win, button, button.getAttribute("data-copy")));
      });
    }
    if (canShare(win)) {
      Array.from(doc.querySelectorAll("[data-share]")).forEach((button) => {
        button.hidden = false;
        button.addEventListener("click", () => share(win, button, button.getAttribute("data-share")));
      });
    }
  }

  return Object.freeze({ boot });
});
