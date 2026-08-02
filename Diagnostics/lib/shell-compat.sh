#!/usr/bin/env bash
# Checks every Diagnostics script still runs on the bash macOS actually ships.
#
#   ./Diagnostics/lib/shell-compat.sh
#
# **macOS ships bash 3.2.57, from 2007, and always will.** Apple stopped at the
# last version before bash went GPLv3, so `/bin/bash` is 3.2 on every Mac and no
# amount of updating changes that. Homebrew's bash 5 installs beside it at
# `/opt/homebrew/bin/bash` and takes over `#!/usr/bin/env bash` for whoever has it
# on their PATH, which is the trap: a script written and tested here works, and
# the same script on a stock Mac dies at the first bash-4 builtin.
#
# It dies badly, too. On 2026-08-02 `pane-move/live.sh` reached `readarray` after
# it had already opened two panes, so the failure left a half-built workspace and
# an error naming a builtin rather than a cause.
#
# This is the check that keeps that from returning. Two arms: every script must
# parse under `/bin/bash` specifically, and none may name a construct 3.2 lacks.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STOCK=/bin/bash

[ -x "$STOCK" ] || { echo "no $STOCK to check against" >&2; exit 2; }

# This file names every banned construct, in the pattern below and in the advice
# it prints, so it is the one script the grep arm cannot be run against. It is
# still parsed like the rest: a linter that does not run is worse than none.
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

fails=0
checked=0

# Constructs bash 3.2 does not have. Each one is a real gap rather than a style
# preference, and each is spelled as it would appear in a script.
#
#   readarray / mapfile   bash 4.0
#   declare -A            bash 4.0, associative arrays
#   ${x,,} ${x^^}         bash 4.0, case modification
#   |&                    bash 4.0, shorthand for 2>&1 |
#   &>>                   bash 4.0, appending both streams
BANNED='(^|[^[:alnum:]_])(readarray|mapfile)[[:space:]]|declare[[:space:]]+-A[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|\|&|&>>'

for script in $(find "$REPO/Diagnostics" -name '*.sh' -type f | sort); do
  # zsh files answer to a different parser and are not this check's business.
  head -1 "$script" | grep -q 'zsh' && continue
  checked=$((checked + 1))
  rel=${script#"$REPO"/}

  if ! "$STOCK" -n "$script" 2>/tmp/shell-compat-$$.err; then
    echo "FAIL  $rel"
    echo "        does not parse under $STOCK ($("$STOCK" --version | head -1 | sed 's/.*version //'))"
    sed 's/^/        /' /tmp/shell-compat-$$.err
    fails=$((fails + 1))
    continue
  fi

  if [ "$script" = "$SELF" ]; then
    echo "ok    $rel (parsed; grep arm skipped, it defines the pattern)"
    continue
  fi

  # Comments stripped first, so a script may explain in prose why it avoids a
  # construct without tripping on having named it.
  if sed 's/#.*//' "$script" | grep -qE "$BANNED"; then
    echo "FAIL  $rel"
    echo "        names a construct bash 3.2 does not have:"
    sed 's/#.*//' "$script" | grep -nE "$BANNED" | sed 's/^/          /'
    fails=$((fails + 1))
    continue
  fi

  echo "ok    $rel"
done
rm -f /tmp/shell-compat-$$.err

# ── Negative control ────────────────────────────────────────────────────
# Every script passing proves nothing on its own: a pattern that matches nothing
# reports a clean sweep forever, and this one is a long alternation where a single
# stray character would silently disable an arm. So it is fed one line per banned
# construct and has to catch all of them.
control_fails=0
while IFS= read -r bad; do
  [ -n "$bad" ] || continue
  printf '%s\n' "$bad" | grep -qE "$BANNED" || {
    echo "NEGATIVE CONTROL FAILED: the pattern does not catch: $bad"
    control_fails=$((control_fails + 1))
  }
done <<'BAD'
readarray -t xs < <(echo hi)
mapfile -t xs < file
declare -A table
echo "${name,,}"
echo "${name^^}"
make build |& tee log
make build &>> log
BAD
# And one line that must NOT match, because a pattern matching everything would
# also pass the arm above while failing every real script.
printf '%s\n' 'while IFS= read -r line; do :; done < file' | grep -qE "$BANNED" && {
  echo "NEGATIVE CONTROL FAILED: the pattern matches ordinary bash 3.2"
  control_fails=$((control_fails + 1))
}
if [ "$control_fails" -gt 0 ]; then
  echo
  echo "  the pattern is broken, so the $checked pass(es) above mean nothing"
  exit 1
fi
echo "ok    ctl  the pattern catches all 7 banned constructs and no ordinary line"

echo
echo "  $checked script(s) checked against $("$STOCK" --version | head -1 | sed 's/.*version //')"
if [ "$fails" -gt 0 ]; then
  echo "  $fails failed"
  echo
  echo "  Rewrite rather than reach for a newer bash. A while-read loop replaces"
  echo "  readarray everywhere, and \$STOCK is what the next person will have."
  exit 1
fi
echo "  all clear"
