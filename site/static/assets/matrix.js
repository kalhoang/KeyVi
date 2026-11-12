// SPDX-License-Identifier: LicenseRef-App-Pending
// Progressive enhancement for the compatibility matrix: category and status filters.
// The page is fully readable and navigable without this script.
(function () {
  "use strict";
  var root = document.querySelector("[data-matrix]");
  if (!root) return;
  var groups = Array.prototype.slice.call(root.querySelectorAll("[data-category-group]"));
  var rows = Array.prototype.slice.call(root.querySelectorAll("tr[data-status]"));
  var mount = document.querySelector("[data-matrix-filters]");
  var labels = JSON.parse(mount.getAttribute("data-labels") || "{}");
  var state = { category: "", status: "" };

  function option(value, text) {
    var el = document.createElement("option");
    el.value = value;
    el.textContent = text;
    return el;
  }

  function makeSelect(id, labelText, allText, items) {
    var wrap = document.createElement("div");
    wrap.className = "field";
    var label = document.createElement("label");
    label.setAttribute("for", id);
    label.textContent = labelText;
    var select = document.createElement("select");
    select.id = id;
    select.appendChild(option("", allText));
    items.forEach(function (item) { select.appendChild(option(item[0], item[1])); });
    wrap.appendChild(label);
    wrap.appendChild(select);
    mount.appendChild(wrap);
    return select;
  }

  var categories = groups.map(function (g) {
    return [g.getAttribute("data-category-group"), g.getAttribute("data-label")];
  });
  var statuses = JSON.parse(mount.getAttribute("data-statuses") || "[]");
  var catSelect = makeSelect("filter-category", labels.category, labels.all, categories);
  var statusSelect = makeSelect("filter-status", labels.status, labels.all, statuses);
  var count = document.createElement("p");
  count.className = "muted";
  count.setAttribute("role", "status");
  mount.appendChild(count);

  function apply() {
    var visible = 0;
    rows.forEach(function (row) {
      var group = row.closest("[data-category-group]");
      var ok = (!state.category || group.getAttribute("data-category-group") === state.category) &&
        (!state.status || row.getAttribute("data-status") === state.status);
      row.hidden = !ok;
      if (ok) visible += 1;
    });
    groups.forEach(function (g) {
      g.hidden = !g.querySelector("tr[data-status]:not([hidden])");
    });
    count.textContent = labels.shown.replace("{n}", String(visible));
  }

  catSelect.addEventListener("change", function () { state.category = catSelect.value; apply(); });
  statusSelect.addEventListener("change", function () { state.status = statusSelect.value; apply(); });
  mount.hidden = false;
  apply();
})();
