// SPDX-License-Identifier: GPL-3.0-or-later
// Landing page (PRD-R73, design 7.3 as amended by design 9): eight sections in order, one module each under
// lib/pages/home/: the hero, the three behaviours (the features anchor), learning (the generated learning demo and its
// four cards), the four "type your way" cards, the apps hub with the Secure Input card, the proof band, the install
// steps and the closing call. Every demo's final state comes from site/demo/frames.json (design 7.4); home.js
// animates them with the vendored anime.js, both classic deferred scripts on the two home pages only (design 7.2,
// ADR 0603).
import { kit } from "../context.mjs";
import { renderApps } from "./home/apps.mjs";
import { renderBehaviours } from "./home/behaviours.mjs";
import { renderCards } from "./home/cards.mjs";
import { renderClosing } from "./home/closing.mjs";
import { renderHero } from "./home/hero.mjs";
import { renderInstall } from "./home/install.mjs";
import { renderLearning } from "./home/learning.mjs";
import { renderProof } from "./home/proof.mjs";

export { downloadBlock } from "./home/download.mjs";

const SECTIONS = [renderHero, renderBehaviours, renderLearning, renderCards, renderApps, renderProof, renderInstall, renderClosing];

export function renderHome(ctx, lang) {
  const kt = { ...kit(ctx, lang), ctx };
  return {
    routeId: "home",
    isHome: true,
    title: kt.p(kt.ui.titles.home),
    description: kt.p(kt.ui.descriptions.home),
    body: `\n    ${SECTIONS.map((render) => render(kt)).join("\n    ")}`,
    styles: ["/assets/home.css"],
    scripts: ["/assets/vendor/anime.umd.min.js", "/assets/home.js"],
  };
}
