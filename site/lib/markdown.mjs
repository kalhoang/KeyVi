// SPDX-License-Identifier: GPL-3.0-or-later
// Minimal Markdown renderer for CHANGELOG.md (Keep a Changelog): headings, lists, paragraphs, code,
// emphasis, links. All text is HTML-escaped first; only https/relative/anchor links are emitted.
import { esc } from "./util.mjs";

export function slugifyHeading(text) {
  return text
    .normalize("NFD").replace(/\p{M}/gu, "").replace(/đ/gi, "d")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

function inline(text) {
  const codeSpans = [];
  let out = esc(text).replace(/`([^`]+)`/g, (_, code) => {
    codeSpans.push(`<code>${code}</code>`);
    return `\u0000${codeSpans.length - 1}\u0000`;
  });
  out = out
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (match, label, href) =>
      /^(https:\/\/|\/|#)/.test(href) ? `<a href="${href}">${label}</a>` : label)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[\s(])\*([^*\s][^*]*)\*(?=[\s).,;:]|$)/g, "$1<em>$2</em>");
  return out.replace(/\u0000(\d+)\u0000/g, (_, index) => codeSpans[Number(index)]);
}

/**
 * Render Markdown to HTML. `baseLevel` shifts heading levels (1 -> baseLevel). `headingId(depth, text)` may
 * return an id for a heading (depth = number of `#` in the source); otherwise the id is a slug of the text.
 */
export function renderMarkdown(source, { baseLevel = 2, idPrefix = "", headingId = () => undefined } = {}) {
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  const html = [];
  let paragraph = [];
  let listOpen = false;
  let inFence = false;
  const fence = [];

  const flushParagraph = () => {
    if (paragraph.length > 0) html.push(`<p>${inline(paragraph.join(" "))}</p>`);
    paragraph = [];
  };
  const closeList = () => {
    if (listOpen) html.push("</ul>");
    listOpen = false;
  };

  for (const line of lines) {
    if (line.startsWith("```")) {
      if (inFence) {
        html.push(`<pre><code>${esc(fence.join("\n"))}</code></pre>`);
        fence.length = 0;
      } else {
        flushParagraph();
        closeList();
      }
      inFence = !inFence;
      continue;
    }
    if (inFence) { fence.push(line); continue; }

    const heading = /^(#{1,6})\s+(.*?)\s*#*$/.exec(line);
    const item = /^\s*[-*+]\s+(.*)$/.exec(line);
    if (heading) {
      flushParagraph();
      closeList();
      const level = Math.min(6, baseLevel + heading[1].length - 1);
      const text = heading[2];
      const id = headingId(heading[1].length, text) ?? idPrefix + slugifyHeading(text);
      html.push(`<h${level} id="${esc(id)}">${inline(text)}</h${level}>`);
    } else if (item) {
      flushParagraph();
      if (!listOpen) html.push("<ul>");
      listOpen = true;
      html.push(`<li>${inline(item[1])}</li>`);
    } else if (line.trim() === "") {
      flushParagraph();
      closeList();
    } else if (/^\s+\S/.test(line) && listOpen) {
      html[html.length - 1] = html[html.length - 1].replace(/<\/li>$/, ` ${inline(line.trim())}</li>`);
    } else {
      closeList();
      paragraph.push(line.trim());
    }
  }
  if (inFence) html.push(`<pre><code>${esc(fence.join("\n"))}</code></pre>`);
  flushParagraph();
  closeList();
  return html.join("\n");
}
