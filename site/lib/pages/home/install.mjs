// SPDX-License-Identifier: GPL-3.0-or-later
// Section 6, install in a minute (design 7.3 item 6): three steps, the permission named as the download page names it
// (with its VERIFY marker), and the brew line again.
import { esc } from "../../util.mjs";
import { brewLine } from "./download.mjs";

export function renderInstall(kt) {
  const { c, f } = kt;
  const install = c.home.install;
  return `<section class="home-section" data-section="install" aria-labelledby="install-title">
      <div class="section-head"><h2 id="install-title">${esc(install.heading)}</h2></div>
      <ol class="install-steps">${install.steps.map((step) => `<li>${f(step)}</li>`).join("")}</ol>
      ${brewLine(kt, install.brewLabel)}
    </section>`;
}
