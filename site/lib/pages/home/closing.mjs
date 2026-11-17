// SPDX-License-Identifier: GPL-3.0-or-later
// Section 7, the closing call (design 7.3 item 7): the message once more, the download call and one quiet line to the
// donate page (PRD-R57; the footer links it too).
import { esc } from "../../util.mjs";
import { downloadBlock } from "./download.mjs";

export function renderClosing(kt) {
  const { c, f } = kt;
  const closing = c.home.closing;
  return `<section class="home-section closing" data-section="closing" aria-labelledby="closing-title">
      <h2 id="closing-title">${esc(closing.heading)}</h2>
      ${downloadBlock(kt, { brew: false })}
      <p class="muted">${f(closing.donateLine)}</p>
    </section>`;
}
