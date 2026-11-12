#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Monthly support metrics from the GitHub API (QA-R50, QA-R46 to QA-R48).

Reports for issues closed (or opened) in the period:
  - reopen rate: closed issues that carry `reopened`, or were reopened, over all closed (target < 10 %)
  - verified versus closed-unverified closes
  - median time to first response by a maintainer (OWNER, MEMBER or COLLABORATOR comment)
  - median time to fix by priority (P0 to P3): opened until the first `fixed-in-beta` or
    `fixed-in-release` label, falling back to the close time
  - share of `compat` issues among issues opened in the period
  - count of `resolution:setting-workaround`

Usage:
  python3 -I scripts/metrics.py [--repo OWNER/NAME] [--month YYYY-MM | --since DATE --until DATE]
                                [--json] [--dump FILE] [--fixture FILE]
Uses `gh api` (authenticated GitHub CLI). --dump saves the raw data; --fixture computes from a
saved dump without network access (tests).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import subprocess
import sys

MAINTAINER = {"OWNER", "MEMBER", "COLLABORATOR"}
FIX_LABELS = ("fixed-in-beta", "fixed-in-release")
PRIORITIES = ("P0", "P1", "P2", "P3")


def gh_json(*args: str):
    result = subprocess.run(["gh", "api", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"gh api {' '.join(args)} failed: {result.stderr.strip()}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def gh_paginated(path: str) -> list:
    result = subprocess.run(["gh", "api", "--paginate", "--slurp", path], capture_output=True, text=True,
                            check=False)
    if result.returncode != 0:
        raise SystemExit(f"gh api {path} failed: {result.stderr.strip()}")
    pages = json.loads(result.stdout or "[]")
    items = []
    for page in pages:
        items.extend(page.get("items", page) if isinstance(page, dict) else page)
    return items


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def month_range(month: str) -> tuple[dt.date, dt.date]:
    start = dt.date.fromisoformat(month + "-01")
    end = (start.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
    return start, end - dt.timedelta(days=1)


def previous_month(today: dt.date) -> str:
    first = today.replace(day=1)
    last_month = first - dt.timedelta(days=1)
    return last_month.strftime("%Y-%m")


def fetch(repo: str, since: dt.date, until: dt.date) -> dict:
    window = f"{since.isoformat()}..{until.isoformat()}"
    closed = gh_paginated(f"search/issues?q=repo:{repo}+is:issue+closed:{window}&per_page=100")
    opened = gh_paginated(f"search/issues?q=repo:{repo}+is:issue+created:{window}&per_page=100")
    details = {}
    for issue in {i["number"]: i for i in closed + opened}.values():
        number = issue["number"]
        events = gh_paginated(f"repos/{repo}/issues/{number}/events?per_page=100")
        comments = gh_paginated(f"repos/{repo}/issues/{number}/comments?per_page=100")
        details[str(number)] = {
            "events": [{"event": e.get("event"), "label": (e.get("label") or {}).get("name"),
                        "created_at": e.get("created_at")} for e in events],
            "comments": [{"author_association": c.get("author_association"),
                          "user": (c.get("user") or {}).get("login"),
                          "created_at": c.get("created_at")} for c in comments],
        }
    slim = lambda items: [{"number": i["number"], "created_at": i["created_at"], "closed_at": i.get("closed_at"),
                           "user": (i.get("user") or {}).get("login"),
                           "labels": [label["name"] for label in i.get("labels", [])]} for i in items]
    return {"repo": repo, "since": since.isoformat(), "until": until.isoformat(),
            "closed": slim(closed), "opened": slim(opened), "details": details}


def hours(delta: dt.timedelta) -> float:
    return round(delta.total_seconds() / 3600.0, 1)


def median_or_none(values: list[float]) -> float | None:
    return round(statistics.median(values), 1) if values else None


def compute(data: dict) -> dict:
    closed = data["closed"]
    opened = data["opened"]
    details = data["details"]

    def reopened(issue) -> bool:
        if "reopened" in issue["labels"]:
            return True
        return any(e["event"] == "reopened" for e in details.get(str(issue["number"]), {}).get("events", []))

    reopen_count = sum(1 for issue in closed if reopened(issue))
    first_response = []
    for issue in opened:
        created = parse_time(issue["created_at"])
        replies = [parse_time(c["created_at"]) for c in details.get(str(issue["number"]), {}).get("comments", [])
                   if c.get("author_association") in MAINTAINER and c.get("user") != issue.get("user")]
        if replies and created:
            first_response.append(hours(min(replies) - created))

    fix_times: dict[str, list[float]] = {p: [] for p in PRIORITIES}
    for issue in closed:
        priority = next((p for p in PRIORITIES if p in issue["labels"]), None)
        if priority is None:
            continue
        created = parse_time(issue["created_at"])
        events = details.get(str(issue["number"]), {}).get("events", [])
        fixed = [parse_time(e["created_at"]) for e in events if e["event"] == "labeled" and e["label"] in FIX_LABELS]
        end = min(fixed) if fixed else parse_time(issue["closed_at"])
        if created and end:
            fix_times[priority].append(hours(end - created))

    compat = sum(1 for issue in opened if "compat" in issue["labels"])
    return {
        "repo": data["repo"],
        "period": {"since": data["since"], "until": data["until"]},
        "closed": len(closed),
        "opened": len(opened),
        "reopenRate": round(reopen_count / len(closed), 3) if closed else None,
        "reopened": reopen_count,
        "verifiedCloses": sum(1 for i in closed if "verified" in i["labels"]),
        "unverifiedCloses": sum(1 for i in closed if "closed-unverified" in i["labels"]),
        "medianFirstResponseHours": median_or_none(first_response),
        "medianTimeToFixHours": {p: median_or_none(v) for p, v in fix_times.items()},
        "compatShare": round(compat / len(opened), 3) if opened else None,
        "settingWorkarounds": sum(1 for i in closed + opened if "resolution:setting-workaround" in i["labels"]),
    }


def markdown(metrics: dict) -> str:
    pct = lambda v: "n/a" if v is None else f"{v * 100:.1f} %"
    num = lambda v: "n/a" if v is None else f"{v}"
    flag = ""
    if metrics["reopenRate"] is not None and metrics["reopenRate"] > 0.10:
        flag = " (over the 10 % target: process review, section 1)"
    lines = [
        f"## Support metrics {metrics['period']['since']} to {metrics['period']['until']} ({metrics['repo']})",
        "",
        f"- Issues closed: {metrics['closed']}; opened: {metrics['opened']}",
        f"- Reopen rate: {pct(metrics['reopenRate'])} ({metrics['reopened']} reopened){flag}",
        f"- Verified closes: {metrics['verifiedCloses']}; closed-unverified: {metrics['unverifiedCloses']}",
        f"- Median time to first response: {num(metrics['medianFirstResponseHours'])} h",
        "- Median time to fix: " + ", ".join(f"{p} {num(v)} h" for p, v in metrics["medianTimeToFixHours"].items()),
        f"- Share of compat issues: {pct(metrics['compatShare'])}",
        f"- resolution:setting-workaround: {metrics['settingWorkarounds']} (each needs a follow-up task, QA-R48)",
    ]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Monthly support metrics (QA-R50).")
    parser.add_argument("--repo")
    parser.add_argument("--month", help="YYYY-MM (default: previous calendar month)")
    parser.add_argument("--since")
    parser.add_argument("--until")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--dump", help="write the raw data to this file")
    parser.add_argument("--fixture", help="compute from a saved dump (no network)")
    args = parser.parse_args(argv)

    if args.fixture:
        with open(args.fixture, encoding="utf-8") as handle:
            data = json.load(handle)
    else:
        if args.since and args.until:
            since, until = dt.date.fromisoformat(args.since), dt.date.fromisoformat(args.until)
        else:
            since, until = month_range(args.month or previous_month(dt.date.today()))
        repo = args.repo
        if not repo:
            repo = gh_json("repos/{owner}/{repo}")["full_name"]
        data = fetch(repo, since, until)
        if args.dump:
            with open(args.dump, "w", encoding="utf-8") as handle:
                json.dump(data, handle, indent=2)
    metrics = compute(data)
    print(json.dumps(metrics, indent=2) if args.json else markdown(metrics), end="" if not args.json else "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
