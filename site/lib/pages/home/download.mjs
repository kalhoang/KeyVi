// SPDX-License-Identifier: GPL-3.0-or-later
// The download call of the hero and the closing section (PRD-R73): the stable DMG with its version and minimum macOS,
// or the disabled "no release yet" state while releases.json has no stable entry (Review Focus 4).
import { macosRequirement } from "../../context.mjs";
import { routePath } from "../../routes.mjs";
import { esc } from "../../util.mjs";

/** The Homebrew line under `label`. */
export function brewLine(kt, label) {
  const { ctx } = kt;
  return `<p class="muted">${esc(label)}</p><code class="cmd">brew install --cask ${esc(ctx.config.homebrewTap)}/${esc(ctx.brand.slug)}</code>`;
}

/** The download button (or its disabled state) with the link to every download; `brew: false` drops the brew line. */
export function downloadBlock(kt, { brew = true } = {}) {
  const { ctx, c, f, lang } = kt;
  const h = c.home;
  const stable = ctx.data.releases.stable;
  const all = `<a href="${esc(routePath("download", lang))}">${esc(h.allDownloads)}</a>`;
  const requirement = stable && macosRequirement(lang, stable.minimumSystemVersion);
  const action = stable
    ? `<a class="btn" href="${esc(stable.url)}">${f(h.downloadBtn, { version: stable.version })}<small>${f(h.downloadSub, { requirement })}</small></a>`
    : `<p class="btn btn-disabled" aria-disabled="true">${esc(h.noReleaseBtn)}<small>${esc(h.preRelease)}</small></p>`;
  return `<div class="actions">${action}${all}</div>${brew ? brewLine(kt, h.brewLabel) : ""}`;
}
