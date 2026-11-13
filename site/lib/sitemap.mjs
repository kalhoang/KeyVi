// SPDX-License-Identifier: GPL-3.0-or-later
// sitemap.xml (with hreflang alternates) and robots.txt.
import { ROUTES } from "./routes.mjs";
import { esc } from "./util.mjs";

export function renderSitemap(brand, lastmod) {
  const abs = (path) => `https://${brand.host}${path}`;
  const entries = ROUTES.map((route) => {
    const alternates = [
      `<xhtml:link rel="alternate" hreflang="vi" href="${esc(abs(route.vi))}"/>`,
      `<xhtml:link rel="alternate" hreflang="en" href="${esc(abs(route.en))}"/>`,
    ].join("\n      ");
    return ["vi", "en"]
      .map((lang) => `  <url>\n    <loc>${esc(abs(route[lang]))}</loc>\n    <lastmod>${lastmod}</lastmod>\n      ${alternates}\n  </url>`)
      .join("\n");
  });
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${entries.join("\n")}
</urlset>
`;
}

export function renderRobots(brand) {
  return `User-agent: *\nAllow: /\n\nSitemap: https://${brand.host}/sitemap.xml\n`;
}
