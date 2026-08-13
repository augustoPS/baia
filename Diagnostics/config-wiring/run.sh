#!/usr/bin/env bash
# Runs Task 6 of the config-wiring plan against the real app.
#
#   ./Diagnostics/config-wiring/run.sh
#
# The screen must be UNLOCKED. A libghostty surface only materialises in a real
# window on an unlocked session, and until it does the pane spawns no pty at all,
# so every check below reports a false negative against a locked screen.
#
# Writes its captures to verify-out/ and prints PASS or FAIL per step. The colour
# checks are automated; the ones marked LOOK need a human to compare two images,
# because "the chrome moved with the surface" is not a pixel assertion.
set -uo pipefail

APP=".build/Build/Products/Debug/baia-dev.app"
# Names the app, its executable, its Application Support directory and the
# pattern that reaches its process and no other copy of baia. Everything below
# used to spell all four for the Release build while launching this one.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/app-identity.sh"

BIN="$APP_EXEC"
# Deliberately shared between the two builds, unlike the session: both read
# `~/.config/baia/config.json`, because testing against settings that are not the
# ones in daily use tests the wrong thing.
CFG="$HOME/.config/baia/config.json"
SESSION="$APP_SESSION"
OUT="verify-out"
LOG="$OUT/stderr.log"

mkdir -p "$OUT"
pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }
look() { echo "  LOOK  $1"; }

# Read out of ioreg rather than through Quartz, which needs pyobjc and is not
# importable from the stock python3 on this machine. An unimportable probe printed
# "unknown", the guard treated that as fine, and the whole run then reported false
# negatives against a locked screen.
require_unlocked() {
    local locked
    locked=$(ioreg -n Root -d1 -a 2>/dev/null | python3 -c "
import sys, plistlib
try:
    users = plistlib.loads(sys.stdin.buffer.read()).get('IOConsoleUsers') or []
except Exception:
    print('unknown'); raise SystemExit
print('locked' if any(u.get('CGSSessionScreenIsLocked') for u in users) else 'unlocked')
" 2>/dev/null)
    case "$locked" in
        locked)
            echo "ABORT: the session is locked."
            echo "  A libghostty surface only materialises in a real window on an unlocked"
            echo "  session, and a pane with no surface spawns no pty, so every check below"
            echo "  would fail for the wrong reason. Unlock and rerun."
            exit 1 ;;
        unlocked) return 0 ;;
        *) echo "  NOTE  could not read the lock state; step 1 will catch it" ;;
    esac
}

stop() { quit_app; sleep 1.5; }

# Launched attached so the decoder's complaints land somewhere readable. They are
# the only channel it has: there is no diagnostics surface in the app yet.
start() {
    "$BIN" >>"$LOG" 2>&1 &
    sleep 5
}

baia_pid()  { pgrep -f "$APP_EXEC_PATTERN" | head -1; }
shells()    { ps -eo pid,ppid,command | grep "[l]ogin -flp" | awk -v b="$(baia_pid)" '$2==b' | wc -l | tr -d ' '; }

# The shared one, since 2026-08-02. This had its own copy that activated
# `application "baia"` and compared the frontmost name against `"baia"`, both of
# which resolve to the Release build while it is installed, so the probe drove
# the daily driver and confirmed it had.
act() { activate_app || exit 1; }

key()  { act; osascript -e "tell application \"System Events\" to $1" >/dev/null 2>&1; sleep 1.2; }

# Pasted, never typed. `keystroke` cannot produce ~ or ^ under U.S. International
# and silently substitutes `a`; see capture.sh for the full account.
type_line() {
    act; printf '%s' "$1" | pbcopy
    osascript -e 'tell application "System Events" to keystroke "v" using command down' \
              -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
    sleep 1.3
}

shot() {
    act; sleep 0.8
    local geom x y w h
    geom=$(osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to get {position, size} of window 1" 2>/dev/null) || return 1
    x=$(echo "$geom"|cut -d, -f1|tr -d ' '); y=$(echo "$geom"|cut -d, -f2|tr -d ' ')
    w=$(echo "$geom"|cut -d, -f3|tr -d ' '); h=$(echo "$geom"|cut -d, -f4|tr -d ' ')
    rm -f "$OUT/$1.png"
    screencapture -x -o -R"$x,$y,$w,$h" "$OUT/$1.png"
    # `screencapture` exits 0 even when it refused to write, so the file has to be
    # tested rather than the status. It refuses a dot-prefixed name outright
    # ("cannot write file to intended destination"), which is what made the probe
    # captures vanish while every `|| return 1` in the callers stayed quiet.
    [ -s "$OUT/$1.png" ] || { echo "        CAPTURE FAILED for $OUT/$1.png" >&2; return 1; }
    echo "        wrote $OUT/$1.png"
}

# Colour helpers. They capture the window, then read the PNG with pixel.py; the
# first version of this shelled out to `sips` to resize a probe to 1x1 and read
# that, which produced no file and reported an empty colour as a measurement.
probe() {
    shot probe >/dev/null || return 1
    python3 Diagnostics/lib/pixel.py "$@" "$OUT/probe.png"
}
# Terminal background, sampled mid-pane: right of the prompt, below the `Last
# login` block, above the bottom edge. It reads a fraction of the whole window
# capture, so both edges have to be cleared deliberately.
#
# The offset used to be justified by "clear of the 22 pt footer", which was
# deleted on 2026-08-13. Mid-pane is still the right answer and the number does
# not move: what the footer occupied is now terminal surface, but the bottom of
# the window is where the glass treatment and the corner rounding land, so a
# sample chased down toward the edge would read chrome and grade it as the
# theme's background. The reason changed; 0.55 did not.
term_bg()  { probe_at 0.75 0.55; }
probe_at() { shot probe >/dev/null || return 1; python3 Diagnostics/lib/pixel.py at "$OUT/probe.png" "$1" "$2"; }
# The default-foreground text of the `Last login` line, which is the reliable
# read on whether a theme applied: a themed shell prompt often uses truecolor
# escapes and is immune to a palette change.
term_fg()  { shot probe >/dev/null || return 1; python3 Diagnostics/lib/pixel.py brightest "$OUT/probe.png" 0.01 0.11 0.30 0.13; }
luma() { python3 -c "
import sys
h=sys.argv[1].lstrip('#')
r,g,b=(int(h[i:i+2],16) for i in (0,2,4))
print(round(0.2126*r+0.7152*g+0.0722*b,1))
" "$1"; }

write_cfg() { python3 -c "
import json,sys
d=json.load(open('$CFG'))
d.update(json.loads(sys.argv[1]))
open('$CFG.tmp','w').write(json.dumps(d,indent=2))
" "$1"; mv "$CFG.tmp" "$CFG"; sleep 2; }   # mv is the rename-over-inode path vim uses

echo "=== Task 6: config wiring, live ==="
require_unlocked
[ -x "$BIN" ] || { echo "ABORT: build first (make build)"; exit 1; }
stop; : > "$LOG"

echo
echo "Step 1: first launch writes the file"
rm -f "$CFG"
start
if [ -f "$CFG" ]; then ok "config.json created"; else bad "config.json missing"; fi
[ "$(stat -f '%Sp' "$CFG" 2>/dev/null)" = "-rw-------" ] && ok "mode 600" || bad "mode is $(stat -f '%Sp' "$CFG" 2>/dev/null)"
# What the first launch writes is every settings key the app has, so a number
# typed here goes stale the day a setting is added and reports a correct app as
# broken. This line said 19 from 2026-08-02 until 2026-08-12, while the app
# wrote 26, and the failure it produced sent a reader looking for a bug in the
# writer. The check that survives a new setting is the shape: a JSON object
# with keys in it, none of them empty.
n=$(python3 -c "
import json, sys
try:
    keys = json.load(open('$CFG'))
except Exception as error:
    print('unreadable: %s' % error); sys.exit(0)
if not isinstance(keys, dict):
    print('not an object'); sys.exit(0)
if not keys:
    print('empty'); sys.exit(0)
if any(not isinstance(k, str) or not k for k in keys):
    print('a key is empty or not a string'); sys.exit(0)
print(len(keys))
" 2>/dev/null)
case "$n" in
  ''|*[!0-9]*) bad "config.json is not a populated object: $n" ;;
  *) ok "$n keys written" ;;
esac
if [ "$(shells)" -ge 1 ]; then
    ok "a pane spawned a shell"
else
    # An abort rather than a failure. Everything after this reads the screen, and
    # a run with no surfaces reports every one of them as broken when the only
    # thing wrong is that nothing is being drawn.
    echo "ABORT: no pty spawned, so no surface exists. The screen is locked or asleep."
    stop; exit 1
fi

echo
echo "Step 2: the terminal reproduces the owner's ghostty"
bg=$(term_bg)
echo "        terminal background reads $bg"
case "$bg" in
    "#141414"|"#131313"|"#151515") ok "background is #141414, so the theme layer did not overwrite it" ;;
    "#000000") bad "background is pure black: backgroundHex was overridden by the theme (render-order bug)" ;;
    *) look "background reads $bg; opacity 0.85 over a wallpaper shifts this, compare against ghostty by eye" ;;
esac
shot 01-defaults
look "01-defaults.png: font 11.5, padding 8, blur, transparent titlebar, block cursor"

echo
echo "Step 3: a live theme change moves the surface, losing nothing"
type_line "sleep 300"
shot 02-before-theme
before_fg=$(term_fg)
write_cfg '{"themeName":"Nord"}'
sleep 2
after_fg=$(term_fg)
shot 03-after-theme
[ "$(shells)" -ge 1 ] && ok "the shell survived the theme change (no surface respawn)" \
    || bad "the pty died: something assigned view.configuration"
# Measured on the `Last login` line, which uses the theme's own foreground. The
# shell prompt is not a witness: a themed prompt emits truecolor escapes and
# looks identical under every palette, which is what made an earlier run read as
# "the theme did nothing".
echo "        default foreground $before_fg -> $after_fg  (Nord declares #d8dee9)"
if [ "$before_fg" != "$after_fg" ]; then
    ok "the theme reached the surface"
else
    bad "the surface did not change: setTheme did not apply, or the name is not in the catalog"
fi
# The witness used to be "the footers moved too", the bar being the one piece of
# per-pane chrome that repainted visibly on a theme change. It was deleted on
# 2026-08-13, so the check names what still repaints: the scrollback is the
# assertion that nothing respawned, and the pane's own chrome is the assertion
# that the change reached more than the character cells.
look "02 vs 03: 'sleep 300' is still on screen, and the pane chrome repainted with the surface rather than only the text"

echo
echo "Step 4: an unknown theme name falls back rather than half-applying"
write_cfg '{"themeName":"Solarized Light"}'
fallback_fg=$(term_fg)
# There is no "Solarized Light" in the catalog; the nearest real names are
# "Solarized Darcula" and "Solarized Osaka Night". The fallback is Dark Pastel.
[ "$fallback_fg" != "$after_fg" ] && ok "an unknown name fell back off Nord" \
    || bad "an unknown name left Nord applied"
write_cfg '{"themeName":"Dark Pastel"}'

echo
echo "Step 5: the inactive-window scrim, the only scrim left"
key 'keystroke "d" using command down'      # split, so the rest of the run has two panes
sleep 2
if [ "$(shells)" -ge 2 ]; then
    ok "split to two panes"
    shot 04-window-key
    lit=$(python3 Diagnostics/lib/pixel.py mean "$OUT/04-window-key.png" 0.05 0.20 0.45 0.90)
    # Captured without `shot`, which activates baia first and would hand the
    # window its key state back before the shutter. The rect is read while baia is
    # still frontmost and reused once Finder has taken over.
    geom=$(osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to get {position, size} of window 1" 2>/dev/null | tr -d ' ')
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1; sleep 1.5
    rm -f "$OUT/05-window-inactive.png"
    screencapture -x -o -R"$geom" "$OUT/05-window-inactive.png"
    if [ -s "$OUT/05-window-inactive.png" ]; then
        dim=$(python3 Diagnostics/lib/pixel.py mean "$OUT/05-window-inactive.png" 0.05 0.20 0.45 0.90)
        hi=$(luma "$lit"); lo=$(luma "$dim")
        echo "        pane luma $hi (window key) -> $lo (window inactive)"
        python3 -c "import sys; sys.exit(0 if float('$lo') < float('$hi') - 0.5 else 1)" \
            && ok "every pane receded when the window stopped being key" \
            || bad "the inactive scrim did nothing: $hi -> $lo"
    else
        bad "the inactive capture failed, so the scrim is untested"
    fi
    act
    look "04 vs 05: both panes recede together, and neither is singled out while the window is key"
else
    bad "the split did not take, so the scrim is untested"
fi

echo
echo "Step 5b: the retired focus keys are reported rather than swallowed"
# The owner's own file carried both of these. They are gone, and a key that
# stopped applying has to be visible: accepting one silently is exactly the
# failure `focusAccent` spent nine days in.
write_cfg '{"focusStyle":"recede","unfocusedScrim":0.28}'
grep -q 'focusStyle` is not a setting' "$LOG" && ok "focusStyle was reported as unknown" \
    || bad "focusStyle was swallowed"
grep -q 'unfocusedScrim` is not a setting' "$LOG" && ok "unfocusedScrim was reported as unknown" \
    || bad "unfocusedScrim was swallowed"
python3 -c "
import json
d=json.load(open('$CFG'))
for k in ('focusStyle','unfocusedScrim'): d.pop(k, None)
open('$CFG.tmp','w').write(json.dumps(d,indent=2))
"; mv "$CFG.tmp" "$CFG"; sleep 2

echo "Step 6: a broken file leaves the last good values standing"
cp "$CFG" "$OUT/.good.json"
printf '{ this is not json' > "$CFG.tmp"; mv "$CFG.tmp" "$CFG"; sleep 2
[ -n "$(baia_pid)" ] && ok "the app survived a malformed config" || bad "the app died on a malformed config"
grep -q "not a JSON object" "$LOG" && ok "the unreadable document was reported" || look "check $LOG for the report"
cp "$OUT/.good.json" "$CFG"; sleep 2

echo
echo "Step 7: the watcher survives a vim-style save"
write_cfg '{"themeName":"Nord"}'
shot 08-after-rename-save
look "08: the theme changed, so the watcher re-armed after the rename"
write_cfg '{"themeName":"Dark Pastel"}'

echo
echo "Step 8: restoreSession"
write_cfg '{"restoreSession":false}'
stop; start
[ "$(shells)" = "1" ] && ok "one fresh pane" || bad "$(shells) shells, expected 1"
write_cfg '{"restoreSession":true}'

echo
echo "Step 9: nothing is leaked"
key 'keystroke "t" using command down'; sleep 2
key 'keystroke "w" using {command down, option down}'; sleep 2
before=$(shells)
stop
after=$(ps -eo pid,ppid,command | grep -c "[l]ogin -flp")
orphans=$(ps -eo pid,ppid,command | grep "[l]ogin -flp" | awk '$2==1' | wc -l | tr -d ' ')
[ "$orphans" = "0" ] && ok "no orphaned shells after quit" || bad "$orphans orphaned shells"

echo
echo "=== $pass passed, $fail failed. Captures in $OUT/ ==="
[ "$fail" -eq 0 ] || exit 1
