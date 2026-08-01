#!/usr/bin/env bash
# Checks executor briefs before a wave spawns anything.
#
#   ./Diagnostics/brief-check/run.sh              the live briefs
#   ./Diagnostics/brief-check/run.sh --self-test  the fixtures, with asserts
#   ./Diagnostics/brief-check/run.sh <brief.md>   a named brief
#
# No app, no window, no shell: this reads markdown and a settings file. It is in
# Diagnostics rather than in a package because what it checks is the harness, and
# because its negative control is three files rather than a fixture builder.
#
# **What it is for.** On 2026-08-01 two of three briefs could not reach their own
# goals, and both said so in writing before an executor started. The observer
# watched for drift against briefs that could not arrive, and was right seven
# times about the wrong question. This runs before that.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SETTINGS="$REPO/Diagnostics/observer-pane/executor-settings.json"
CHECK="$HERE/check.py"

[ -f "$SETTINGS" ] || { echo "ABORT: no $SETTINGS" >&2; exit 2; }

if [ "${1:-}" != "--self-test" ]; then
  if [ "$#" -gt 0 ]; then
    exec python3 "$CHECK" --repo "$REPO" --settings "$SETTINGS" "$@"
  fi
  briefs=("$REPO"/Diagnostics/observer-pane/briefs/*.md)
  [ -e "${briefs[0]}" ] || { echo "ABORT: no briefs to check" >&2; exit 2; }
  exec python3 "$CHECK" --repo "$REPO" --settings "$SETTINGS" "${briefs[@]}"
fi

# ── Self-test ───────────────────────────────────────────────────────────
# The fixtures are the 2026-08-01 briefs kept verbatim, and the expected verdicts
# sit beside them. The live briefs are meant to be rewritten until they pass, so
# without the copies this check would soon have nothing left to fail against and
# would report a clean sweep forever.
echo "self-test against the 2026-08-01 fixtures"
fails=0

while read -r name want; do
  case "$name" in ''|\#*) continue ;; esac
  python3 "$CHECK" --repo "$REPO" --settings "$SETTINGS" \
      "$HERE/fixtures/$name.md" >/dev/null 2>&1
  case "$?:$want" in
    0:pass|1:fail) printf '  ok    %-18s %s\n' "$name" "$want" ;;
    *)             printf '  FAIL  %-18s wanted %s\n' "$name" "$want"
                   fails=$((fails + 1)) ;;
  esac
done < "$HERE/fixtures/expected.txt"

# The criterion the spec states, checked rather than promised: a check that
# recognises its own fixtures by name proves nothing about the next brief.
for name in $(sed -n 's/^\([a-z-]*\) \(pass\|fail\)$/\1/p' "$HERE/fixtures/expected.txt"); do
  if grep -q -- "$name" "$CHECK"; then
    printf '  FAIL  ctl  check.py names the fixture %s, so it is matching rather than deriving\n' "$name"
    fails=$((fails + 1))
  fi
done
[ "$fails" -eq 0 ] && printf '  ok    ctl  check.py names none of its fixtures\n'

echo
if [ "$fails" -gt 0 ]; then printf '  %d self-test failure(s)\n' "$fails"; exit 1; fi
printf '  self-test passed\n'
