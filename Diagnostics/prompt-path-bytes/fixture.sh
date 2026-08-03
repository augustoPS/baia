#!/bin/bash
# Builds a repository holding a filename this machine cannot create, so the one
# thing the byte path exists for can be clicked on.
#
# **The name cannot be written to disk, and that is the point rather than a
# workaround.** APFS refuses a filename that is not valid UTF-8 at the point of
# creation, so `printf > "caf\xe9.txt"` fails on macOS and always will. Git has no
# such rule: a filename on a Unix filesystem is a byte string with two rules, no
# NUL and no slash, and git records whatever the index holds. A clone from an
# ext4, NFS or ExFAT checkout carries exactly these names into the index and into
# tree objects on a Mac that could not have made them, and git lists them.
#
# So the entry is written straight into a tree object with `mktree`, which takes
# the name as bytes, and read into the index with `read-tree`. `git status`
# reports it `AD`: in the index, absent from the worktree. That is not a contrived
# state, it is what the cloned-from-elsewhere case looks like on this machine
# after checkout declines the name.
#
# Verified 2026-08-02 that both surfaces see it: `git ls-files -z` and
# `git status --porcelain=v2 -z` each emit the 0xE9 byte unchanged, and those are
# the two commands `GitCommand` runs for the Files tree and the Changes list.
set -euo pipefail

OUT=${TMPDIR:-/tmp}/baia-prompt-path-bytes-fixture

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$OUT"

git init -q .
git config user.email fixture@baia
git config user.name fixture

printf 'base\n' >README.md
git add README.md
git commit -qm "base"

mkdir -p src
printf 'plain\n' >src/plain.txt
git add src/plain.txt
git commit -qm "plain"

# The one that matters. `caf<E9>.txt` is the Latin-1 spelling of `café.txt`, and
# 0xE9 alone is not valid UTF-8: through a Swift `String` it becomes U+FFFD, three
# bytes naming nothing, and every unreadable byte in every filename collapses onto
# that same replacement so two files send one path.
BLOB=$(printf 'accented\n' | git hash-object -w --stdin)
TREE=$(printf '100644 blob %s\tcaf\xe9.txt\n' "$BLOB" | git mktree)
git read-tree --prefix=src/ "$TREE"

# No expectation files any more. They held the bytes the click had to produce,
# back when this probe graded what arrived at the shell; the answer now is that
# nothing arrives, because `PromptPath` refuses a path the line editor cannot
# hold. Which refusal this row produces is pinned in `PromptPathTests`, where it
# needs no window, and the sentence the footer shows is graded by eye.
#
# Removing them also takes two rows out of the sidebar. They were untracked, so
# `ls-files --others` listed them at rows 4 and 5; without them `README.md` moves
# up and rows 1 to 3, which are the ones clicked, do not move.

echo "[+] fixture at $OUT"
