#!/usr/bin/env python3
"""Refresh the auto-generated "Live status" block in HANDOFF.md.

Run by .github/workflows/handoff.yml on every push to main, every release,
and once a day. Safe to run locally too: without network access it still
fills in versions and recent commits.

Privacy: only public facts are written (versions, release tags, commit
subjects, PR titles). Commit author names and emails are never read.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HANDOFF = os.path.join(ROOT, "HANDOFF.md")
REPO = os.environ.get("GITHUB_REPOSITORY", "raetori/ultra-hd-youtube-downloader")
START = "<!-- LIVE-STATUS:START (filled in by .github/scripts/update-handoff.py, do not edit by hand) -->"
END = "<!-- LIVE-STATUS:END -->"


def read(path):
    try:
        with open(os.path.join(ROOT, path)) as f:
            return f.read().strip()
    except OSError:
        return "?"


def api(path):
    req = urllib.request.Request("https://api.github.com/repos/%s/%s" % (REPO, path))
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "cosmograv-handoff")
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except Exception as e:  # network blocked or rate limited: leave that part out
        print("note: could not read %s (%s)" % (path, e), file=sys.stderr)
        return None


def clean(text):
    # Keep table cells on one line and never let an email address slip in.
    text = re.sub(r"\S+@\S+", "(hidden)", text or "")
    return text.replace("|", "/").replace("\n", " ").strip()


def git(*args):
    return subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True).stdout


def build():
    lines = []
    lines.append("| | In the code (main) | Latest published release |")
    lines.append("|---|---|---|")

    releases = api("releases?per_page=40") or []
    def newest(prefix):
        for r in releases:
            tag = r.get("tag_name", "")
            if r.get("draft") or not re.match(r"^%s\d" % re.escape(prefix), tag):
                continue
            return "%s (%s)" % (tag, (r.get("published_at") or "")[:10])
        return "unknown" if not releases else "none yet"

    lines.append("| Mac app | %s (`app/VERSION`) | %s |" % (read("app/VERSION"), newest("v")))
    lines.append("| Windows app | %s (`windows/VERSION`) | %s |" % (read("windows/VERSION"), newest("win-v")))
    try:
        ext = json.loads(read("extension/manifest.json")).get("version", "?")
    except ValueError:
        ext = "?"
    lines.append("| Chrome extension | %s (`extension/manifest.json`) | ships inside the Mac app |" % ext)
    lines.append("")

    pulls = api("pulls?state=open&per_page=20")
    lines.append("**Open pull requests**")
    lines.append("")
    if pulls is None:
        lines.append("- (could not check)")
    elif not pulls:
        lines.append("- None")
    else:
        for p in pulls:
            lines.append("- #%d %s (branch `%s`, opened %s)" % (
                p["number"], clean(p["title"]), clean(p["head"]["ref"]), p["created_at"][:10]))
    lines.append("")

    lines.append("**Last 15 changes on main** (newest first)")
    lines.append("")
    log = git("log", "--no-merges", "--invert-grep", "--grep=^Handoff: refresh live status", "-15", "--date=short", "--format=%ad\t%h\t%s")
    for row in log.strip().splitlines():
        date, sha, subject = row.split("\t", 2)
        lines.append("- %s `%s` %s" % (date, sha, clean(subject)))
    return "\n".join(lines)


def main():
    with open(HANDOFF) as f:
        doc = f.read()
    if START not in doc or END not in doc:
        sys.exit("HANDOFF.md is missing the LIVE-STATUS markers")
    head, rest = doc.split(START, 1)
    old, tail = rest.split(END, 1)
    body = build()
    # The date line only changes when something else did, so the daily run
    # doesn't make an empty-news commit.
    if old.strip().split("\n", 1)[-1].strip() == body.strip():
        print("HANDOFF.md already current")
        return
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    new = head + START + "\n_Last refreshed " + now + "._\n\n" + body + "\n" + END + tail
    if new != doc:
        with open(HANDOFF, "w") as f:
            f.write(new)
        print("HANDOFF.md refreshed")
    else:
        print("HANDOFF.md already current")


if __name__ == "__main__":
    main()
