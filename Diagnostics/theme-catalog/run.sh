#!/bin/bash
# Builds and runs the theme-catalog sweep. Output goes to a scratch directory;
# it writes nothing into the repo, opens no window, and touches no running app.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT=${TMPDIR:-/tmp}/baia-theme-catalog-probe
cd "$ROOT"

# The build is `build.sh`, which is also the whole of what a reviewer inspecting
# the sweep needs. Splitting it out is not tidiness: transcribing these `swiftc`
# lines into one Bash call requires a one-line shell function, and a brace
# holding a quote reads to Claude Code's command analyser as brace-expansion
# obfuscation, which no allow rule can pre-approve. `build.sh` says the rest.
"$HERE/build.sh" "$OUT" >/dev/null

# The arm, then one negative control per rule it grades. `set -e` makes the arm
# the test; the controls are inverted, so a control that stops failing fails the
# run as loudly as an arm that stops passing.
#
# Four rather than one, and that is a finding rather than thoroughness. The
# first version had a single control that replaced `nightshade` with the bar it
# is drawn on, and it passed: `nightshade` already clears 4.5:1 raw on none of
# the 485, the repair chain lifts a bar-coloured accent like any other, and
# `derived(from:)` still had a palette to walk. It damaged nothing any pin or
# rule could see. Each control now imitates one specific wrong measurement.
"$OUT/catalogsweep"
echo

for control in break-repair break-derive break-pins break-distribution; do
  if "$OUT/catalogsweep" "$control"; then
    echo "CONTROL DID NOT FAIL: $control passes, so the rule it damages is not being graded"
    exit 1
  fi
  echo "($control failed, as it must)"
  echo
done

echo "the sweep passes and all four controls fail"
