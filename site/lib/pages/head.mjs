// SPDX-License-Identifier: GPL-3.0-or-later
// The head of an inner page (design 7.5): the h1, the optional lede and any line that belongs with them, in one block
// that style.css spaces the same way on every inner page. Callers pass markup they have already escaped or filled.

/**
 * @param {string} h1Html the page heading, escaped
 * @param {string} [ledeHtml] the lede paragraph's content, escaped or filled; omitted when empty
 * @param {string} [moreHtml] further markup inside the head, after the lede
 */
export function pageHead(h1Html, ledeHtml = "", moreHtml = "") {
  const lede = ledeHtml ? `\n      <p class="lede">${ledeHtml}</p>` : "";
  const more = moreHtml ? `\n      ${moreHtml}` : "";
  return `<div class="page-head">
      <h1>${h1Html}</h1>${lede}${more}
    </div>`;
}
