#!/usr/bin/env bash
# Surface 1: a fresh directory raises Claude Code's workspace-trust dialog, which
# halts the pane before any work starts and which no project settings.json can
# pre-approve. The flag lives per path in ~/.claude.json as
# `projects["<path>"].hasTrustDialogAccepted`.
#
# Answering the dialog by hand is not enough: it persists on graceful shutdown,
# so a run whose sessions are killed loses the acceptance and the next run halts
# in exactly the same place. Measured 2026-08-01.
#
# Usage: trust-worktrees.sh <dir> [<dir> ...]
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 <dir> [<dir> ...]" >&2; exit 2; }

CFG="$HOME/.claude.json"
[ -f "$CFG" ] || { echo "no $CFG" >&2; exit 2; }

cp "$CFG" "$CFG.bak-observer"

python3 - "$CFG" "$@" <<'PY'
import json, sys, os, tempfile

cfg, dirs = sys.argv[1], sys.argv[2:]
with open(cfg) as fh:
    d = json.load(fh)
projects = d.setdefault("projects", {})

changed = []
for raw in dirs:
    path = os.path.abspath(os.path.expanduser(raw))
    entry = projects.setdefault(path, {})
    if entry.get("hasTrustDialogAccepted") is not True:
        entry["hasTrustDialogAccepted"] = True
        changed.append(path)
    # Present on every real entry; set so the shape matches what Claude Code writes.
    entry.setdefault("hasClaudeMdExternalIncludesApproved", False)
    entry.setdefault("hasClaudeMdExternalIncludesWarningShown", False)

# Write through a temp file in the same directory so a crash cannot truncate the
# real config, which is the only record of every project's settings.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cfg))
with os.fdopen(fd, "w") as fh:
    json.dump(d, fh, indent=2)
os.replace(tmp, cfg)

print(f"trusted {len(changed)} new path(s)")
for p in changed:
    print("  " + p)
PY
