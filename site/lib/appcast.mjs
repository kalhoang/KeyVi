// SPDX-License-Identifier: GPL-3.0-or-later
// Copies the Sparkle feed to dist/appcast.xml. The URL never moves (PRD-R73, PLT-R1101); publish-release
// owns the file's content. Brand tokens are filled so the checked-in initial feed carries no literal name.
import { readTextIfExists } from "./util.mjs";

const EMPTY_FEED = (host) => `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Updates</title>
    <link>https://${host}/appcast.xml</link>
    <description>Most recent updates</description>
    <language>en</language>
  </channel>
</rss>
`;

function xmlEscape(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export async function renderAppcast(staticAppcastPath, brand) {
  const source = await readTextIfExists(staticAppcastPath);
  if (source === undefined) return EMPTY_FEED(xmlEscape(brand.host));
  return source
    .replace(/\{\{AppName\}\}/g, xmlEscape(brand.name))
    .replace(/\{\{host\}\}/g, xmlEscape(brand.host));
}
