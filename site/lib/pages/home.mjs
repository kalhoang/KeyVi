// SPDX-License-Identifier: GPL-3.0-or-later
// Landing page (PRD-R73, design 7.3): seven sections in order, one module each under lib/pages/home/: the hero, the
// three behaviours (the features anchor), the six cards, the apps hub with the Secure Input card, the proof band, the
// install steps and the closing call. Every demo's final state comes from site/demo/frames.json (design 7.4).
import { kit } from "../context.mjs";
import { renderApps } from "./home/apps.mjs";
import { renderBehaviours } from "./home/behaviours.mjs";
import { renderCards } from "./home/cards.mjs";
import { renderClosing } from "./home/closing.mjs";
import { renderHero } from "./home/hero.mjs";
import { renderInstall } from "./home/install.mjs";
import { renderProof } from "./home/proof.mjs";

export { downloadBlock } from "./home/download.mjs";

const SECTIONS = [renderHero, renderBehaviours, renderCards, renderApps, renderProof, renderInstall, renderClosing];

export function renderHome(ctx, lang) {
  const kt = { ...kit(ctx, lang), ctx };
  return {
    routeId: "home",
    isHome: true,
    title: kt.p(kt.ui.titles.home),
    description: kt.p(kt.ui.descriptions.home),
    body: `\n    ${SECTIONS.map((render) => render(kt)).join("\n    ")}`,
    styles: ["/assets/home.css"],
  };
}
