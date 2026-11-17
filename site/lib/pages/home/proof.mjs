// SPDX-License-Identifier: GPL-3.0-or-later
// Section 5, three things you can check (PRD-R73, design 7.3 item 5): no data collection, free, open source, on the
// dark band (dark in both schemes).
import { esc } from "../../util.mjs";

export function renderProof(kt) {
  const { c, f } = kt;
  const h = c.home;
  const items = h.proof.map((item) => {
    const link = item.link ? `<p><a href="${esc(f(item.link))}"${item.external ? ' rel="noopener"' : ""}>${esc(item.linkText)}</a></p>` : "";
    return `<li><h3>${esc(item.h)}</h3><p>${f(item.p)}</p>${link}</li>`;
  });
  return `<section class="band-dark" data-section="proof" aria-labelledby="proof-title">
      <h2 id="proof-title">${esc(h.proofHeading)}</h2>
      <ul class="proof">${items.join("")}</ul>
    </section>`;
}
