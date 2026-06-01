#!/usr/bin/env python3
"""frontier.py — aggregate the cluster's live research frontier into work items.

Scans the multi-repo state (informal math repo + the Lean formalization repo) and emits a
normalized list of work items (see meta/coordination/PROTOCOL.md). The dispatcher consumes
this; run it standalone to see what the cluster currently *could* be doing.

Usage:
    frontier.py [--json] [--cache-dir DIR]

stdlib only. Clones/pulls the source repos shallowly into a cache dir, then parses the
canonical work locations. Designed to fail soft: a repo or file it can't read is skipped,
not fatal.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, asdict

REPOS = {
    "math": "https://github.com/eliottcassidy2000/math.git",
    "math-lean": "https://github.com/claude-monad/math-lean.git",
}

# (relative path in repo, item type, best role) for line/file-scanned sources.
LINE_SOURCES = [
    ("math", "00-navigation/OPEN-QUESTIONS.md", "open-question", "researcher"),
    ("math", "05-knowledge/hypotheses/INDEX.md", "hypothesis", "researcher"),
]
DIR_SOURCES = [
    ("math", "02-court/active", "court", "reviewer"),
    ("math-lean", "candidates", "formalize", "formalizer"),
]


@dataclass
class WorkItem:
    id: str
    type: str
    source: str
    priority: float
    best_role: str
    status: str = "open"
    owner: str | None = None


def sh(args, cwd=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def ensure_repo(name: str, url: str, cache_dir: str) -> str | None:
    """Shallow-clone or fast-forward a repo into cache_dir. Returns path or None."""
    path = os.path.join(cache_dir, name)
    if os.path.isdir(os.path.join(path, ".git")):
        sh(["git", "-C", path, "pull", "--ff-only", "--depth", "1"])
    else:
        r = sh(["git", "clone", "--depth", "1", url, path])
        if r.returncode != 0:
            print(f"[frontier] WARN cannot clone {name}: {r.stderr.strip()}", file=sys.stderr)
            return None
    return path


# A "red" / high-priority marker in the navigation files.
RED = re.compile(r"\b(red|priority|urgent|🔴|high)\b", re.IGNORECASE)


def scan_line_source(repo_path, repo, rel, itype, role, items):
    fp = os.path.join(repo_path, rel)
    if not os.path.isfile(fp):
        return
    with open(fp, errors="ignore") as f:
        for i, line in enumerate(f, 1):
            s = line.strip()
            # treat list items / headings as candidate questions
            if not (s.startswith(("- ", "* ", "## ", "### ")) and len(s) > 6):
                continue
            prio = 0.8 if RED.search(s) else 0.4
            items.append(WorkItem(
                id=f"{itype[:2]}-{repo}-{i}",
                type=itype,
                source=f"{repo}:{rel}#L{i}",
                priority=prio,
                best_role=role,
            ))


def scan_dir_source(repo_path, repo, rel, itype, role, items):
    d = os.path.join(repo_path, rel)
    if not os.path.isdir(d):
        return
    for name in sorted(os.listdir(d)):
        if name.startswith(".") or name.lower() == "readme.md":
            continue
        stem = os.path.splitext(name)[0]
        # court cases and fresh formalize candidates carry chain pressure → higher priority
        prio = 0.7 if itype in ("court", "formalize") else 0.5
        items.append(WorkItem(
            id=f"{itype[:2]}-{stem}",
            type=itype,
            source=f"{repo}:{rel}/{name}",
            priority=prio,
            best_role=role,
        ))


def build_frontier(cache_dir: str) -> list[WorkItem]:
    paths = {n: ensure_repo(n, u, cache_dir) for n, u in REPOS.items()}
    items: list[WorkItem] = []
    for repo, rel, itype, role in LINE_SOURCES:
        if paths.get(repo):
            scan_line_source(paths[repo], repo, rel, itype, role, items)
    for repo, rel, itype, role in DIR_SOURCES:
        if paths.get(repo):
            scan_dir_source(paths[repo], repo, rel, itype, role, items)
    items.sort(key=lambda w: w.priority, reverse=True)
    return items


def main():
    ap = argparse.ArgumentParser(description="aggregate the cluster research frontier")
    ap.add_argument("--json", action="store_true", help="emit JSON (default: human table)")
    ap.add_argument("--cache-dir", default=os.path.join(tempfile.gettempdir(), "monad-frontier"))
    args = ap.parse_args()
    os.makedirs(args.cache_dir, exist_ok=True)

    items = build_frontier(args.cache_dir)

    if args.json:
        print(json.dumps([asdict(w) for w in items], indent=2))
        return
    if not items:
        print("frontier empty (no source repos reachable, or no open work).")
        return
    print(f"{'PRIO':>5}  {'ROLE':<11} {'TYPE':<13} SOURCE")
    print("-" * 72)
    for w in items:
        print(f"{w.priority:>5.2f}  {w.best_role:<11} {w.type:<13} {w.source}")
    print(f"\n{len(items)} work item(s) on the frontier.")


if __name__ == "__main__":
    main()
