// SPDX-License-Identifier: LicenseRef-App-Pending
// Website analytics loader (Pa, 2026-11-13, Q7; ADR 0602). `node site/build.mjs` writes it to
// assets/analytics.<content hash>.js only when site/config.json sets analytics.posthogKey, and layout.mjs loads it on website pages only (never in the
// app, never on release-notes pages). It loads PostHog's browser library (major version 1) from the PostHog asset
// host named by the script tag and starts it in cookieless mode: no cookies, no browser storage, no person
// profiles, page views only (no autocapture, session recording, surveys, heatmaps, web vitals or feature flags).
// PostHog's project settings must have cookieless tracking enabled and client IP data discarded
// (docs/runbooks/site-deploy.md section 6).
(() => {
  "use strict";
  const tag = document.currentScript;
  const key = tag?.dataset.posthogKey;
  const apiHost = tag?.dataset.posthogHost;
  const assetsHost = tag?.dataset.posthogAssets;
  if (!key || !apiHost || !assetsHost) return;
  const library = document.createElement("script");
  library.src = `${assetsHost}/static/1/array.js`;
  library.async = true;
  library.addEventListener("load", () => {
    window.posthog?.init(key, {
      api_host: apiHost,
      cookieless_mode: "always",
      persistence: "memory",
      person_profiles: "never",
      autocapture: false,
      capture_pageview: true,
      capture_dead_clicks: false,
      capture_exceptions: false,
      capture_heatmaps: false,
      capture_performance: false,
      disable_session_recording: true,
      disable_surveys: true,
      advanced_disable_flags: true,
      respect_dnt: true,
    });
  });
  document.head.appendChild(library);
})();
