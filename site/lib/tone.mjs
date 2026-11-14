// SPDX-License-Identifier: GPL-3.0-or-later
// Tone placement check for the site's Vietnamese text (decision 0005 Q13: the traditional placement is the default
// and the app's catalogs follow it, so the site writes hòa, thủy, xóa, tùy, khóa too). Used by site/test.mjs.
import { readFile } from "node:fs/promises";

// Second vowel of the clusters oa, oe and uy, with a tone mark.
const TONED_SECOND_VOWEL = { o: "áàảãạéèẻẽẹ", u: "ýỳỷỹỵ" };

/** The modern-style examples of the tone placement setting (PRD-R24, D2), allowed only inside <em> on the site. */
export const TONE_SETTING_EXAMPLES = new Set(["hoà", "thuỷ", "khoẻ"]);

/** Words with the modern placement: oa, oe or uy closing the word with the tone on the second vowel (hoá, khoẻ,
 * tuỳ). A following letter makes a closed syllable or a triphthong, marked on that vowel in both styles (hoàn,
 * xoắn, ngoài, khuỷu); after q the u is part of the onset qu, so quý is right in both styles. */
export function modernToneWords(text) {
  return (text.normalize("NFC").match(/\p{L}+/gu) ?? []).filter((word) => {
    const lower = word.toLowerCase();
    const first = lower.at(-2) ?? "";
    if (!(TONED_SECOND_VOWEL[first] ?? "").includes(lower.at(-1))) return false;
    return !(first === "u" && lower.slice(0, -2).endsWith("q"));
  });
}

/** Modern-placement words of a page or source, except the setting's examples written as <em>example</em>. */
export function siteToneOffenders(text) {
  const withoutExamples = text.replace(/<em>(\p{L}+)<\/em>/gu, (whole, word) => (TONE_SETTING_EXAMPLES.has(word) ? "" : whole));
  return modernToneWords(withoutExamples);
}

/** `label: word` for every offending word in `files`; `label` maps a path to its name in the report. */
export async function toneOffendersInFiles(files, label = (file) => file) {
  const offenders = [];
  for (const file of files) for (const word of siteToneOffenders(await readFile(file, "utf8"))) offenders.push(`${label(file)}: ${word}`);
  return offenders;
}
