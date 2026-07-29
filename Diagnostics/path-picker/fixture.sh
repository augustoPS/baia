#!/bin/bash
# Builds a repository holding every name the path picker has to survive, so the
# live check is repeatable rather than remembered. Writes nothing into the repo.
#
# The click itself cannot be scripted, for the reason the control channel's last
# check stayed manual: nothing here can drive a mouse or read NSApp.keyWindow.
# So this prepares the ground and the checks below are done by hand.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${TMPDIR:-/tmp}/baia-path-picker-fixture

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$OUT"

git init -q .
git config user.email fixture@baia
git config user.name fixture

# Committed first, so the repository has a HEAD and the panel has a branch to
# name. Everything after this is what the check clicks on.
printf 'base\n' >README.md
git add README.md
git commit -qm "base"

mkdir -p src/deeply/nested/directory

printf 'plain\n' >src/plain.txt
printf 'space\n' >"src/a space.txt"
printf 'quote\n' >'src/quo"te.txt'
printf 'apostrophe\n' >"src/apo'strophe.txt"
printf 'accent\n' >src/café.txt
printf 'tilde\n' >src/'~notes.txt'
printf 'equals\n' >src/'=lookup.txt'
printf 'dash\n' >src/-rf.txt
printf 'deep\n' >src/deeply/nested/directory/leaf.txt

# The refusals. Both names are legal on macOS and both would drive zsh's line
# editor rather than land on the prompt line, so both rows must refuse.
printf 'tab\n' >$'src/ctrl\tname.txt'
printf 'escape\n' >$'src/esc\033[Dname.txt'

# A staged change and a rename, so the changes list holds more than untracked
# rows and the rename's original path is on the wire as an entry of its own.
printf 'staged\n' >src/staged.txt
git add src/staged.txt
git commit -qm "staged"
printf 'edited\n' >src/staged.txt
git mv README.md READING.md

echo "[+] fixture at $OUT"
echo "[+] open a pane there, turn the sidebar on, and check by hand:"
echo "    1. src/plain.txt sends bare and the trailing space lands"
echo "    2. three clicks in a row accumulate into three arguments"
echo "    3. 'a space.txt' arrives as one argument: click it after typing ls"
echo "    4. ctrl<TAB>name.txt and esc<ESC>[Dname.txt both refuse, prompt unmoved"
echo "    5. clicking while an agent is mid-run inserts into its prompt"
echo "[+] and the ones the unit tests already pin, worth seeing once:"
echo "    ~notes.txt, =lookup.txt and -rf.txt must not expand or read as options"
