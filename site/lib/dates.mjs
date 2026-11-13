// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic date helpers (no Intl dependence so output is identical on every machine).
const MONTHS_EN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DAY_MS = 86_400_000;

export function parseIsoDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value ?? ""));
  if (!match) return undefined;
  const time = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  return Number.isNaN(time) ? undefined : new Date(time);
}

export function isoDay(date) {
  return date.toISOString().slice(0, 10);
}

export function formatDate(lang, value) {
  const date = parseIsoDate(value);
  if (!date) return "";
  const day = date.getUTCDate();
  const month = date.getUTCMonth();
  const year = date.getUTCFullYear();
  return lang === "vi"
    ? `${String(day).padStart(2, "0")}/${String(month + 1).padStart(2, "0")}/${year}`
    : `${day} ${MONTHS_EN[month]} ${year}`;
}

export function daysBetween(earlier, later) {
  return Math.floor((later.getTime() - earlier.getTime()) / DAY_MS);
}
