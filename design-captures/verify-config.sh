#!/usr/bin/env bash
# Runs Task 6 of the config-wiring plan against the real app.
#
#   ./design-captures/verify-config.sh
#
# The screen must be UNLOCKED. A libghostty surface only materialises in a real
# window on an unlocked session, and until it does the pane spawns no pty at all,
# so every check below reports a false negative against a locked screen.
#
# Writes its captures to verify-out/ and prints PASS or FAIL per step. The colour
# checks are automated; the ones marked LOOK need a human to compare two images,
# because "the footers moved with the surface" is not a pixel assertion.
set -uo pipefail

APP=".build/Build/Products/Debug/baia.app"
BIN="$APP/Contents/MacOS/baia"
CFG="$HOME/.config/baia/config.json"
SESSION="$HOME/Library/Application Support/baia/session.json"
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

stop() { pkill -f "baia.app/Contents/MacOS/baia" 2>/dev/null; sleep 1.5; }

# Launched attached so the decoder's complaints land somewhere readable. They are
# the only channel it has: there is no diagnostics surface in the app yet.
start() {
    "$BIN" >>"$LOG" 2>&1 &
    sleep 5
}

baia_pid()  { pgrep -f "baia.app/Contents/MacOS/baia" | head -1; }
shells()    { ps -eo pid,ppid,command | grep "[l]ogin -flp" | awk -v b="$(baia_pid)" '$2==b' | wc -l | tr -d ' '; }

act() {
    for _ in 1 2 3 4 5 6; do
        osascript -e 'tell application "baia" to activate' >/dev/null 2>&1
        sleep 0.5
        [ "$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)" = "baia" ] && return 0
    done
    echo "ABORT: baia never came to the front"; exit 1
}

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
    geom=$(osascript -e 'tell application "System Events" to tell process "baia" to get {position, size} of window 1' 2>/dev/null) || return 1
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
    python3 design-captures/pixel.py "$@" "$OUT/probe.png"
}
# Terminal background, sampled well clear of the text and the 22 pt footer.
term_bg()  { probe_at 0.75 0.55; }
probe_at() { shot probe >/dev/null || return 1; python3 design-captures/pixel.py at "$OUT/probe.png" "$1" "$2"; }
# The default-foreground text of the `Last login` line, which is the reliable
# read on whether a theme applied: a themed shell prompt often uses truecolor
# escapes and is immune to a palette change.
term_fg()  { shot probe >/dev/null || return 1; python3 design-captures/pixel.py brightest "$OUT/probe.png" 0.01 0.11 0.30 0.13; }
# Mean of the right-hand pane, for the scrim.
pane_mean() { shot probe >/dev/null || return 1; python3 design-captures/pixel.py mean "$OUT/probe.png" "$1" 0.20 "$2" 0.90; }

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
n=$(python3 -c "import json;print(len(json.load(open('$CFG'))))" 2>/dev/null)
[ "$n" = "21" ] && ok "21 keys" || bad "$n keys, expected 21"
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
look "02 vs 03: 'sleep 300' is still on screen and the footers moved too"

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
echo "Step 5: the scrim, which needs two panes to mean anything"
key 'keystroke "d" using command down'      # split, so one pane is unfocused
sleep 2
if [ "$(shells)" -ge 2 ]; then
    ok "split to two panes"
    write_cfg '{"unfocusedScrim":0}'
    off=$(pane_mean 0.05 0.45); shot 04-scrim-off
    write_cfg '{"unfocusedScrim":0.34}'
    max=$(pane_mean 0.05 0.45); shot 05-scrim-max
    lo=$(luma "$off"); hi=$(luma "$max")
    echo "        unfocused pane luma $lo (scrim 0) -> $hi (scrim 0.34)"
    python3 -c "import sys; sys.exit(0 if float('$hi') < float('$lo') - 0.5 else 1)" \
        && ok "the unfocused pane darkened" \
        || bad "the scrim did nothing: $lo -> $hi"
    # Deliberately from a value 0.9 does NOT clamp onto. The report used to sit
    # behind the settings-changed guard, so clamping 0.9 down onto a live 0.34
    # produced no diagnostic at all.
    write_cfg '{"unfocusedScrim":0.28}'
    write_cfg '{"unfocusedScrim":0.9}'
    grep -q "unfocusedScrim" "$LOG" && ok "0.9 was clamped and reported on stderr" \
        || bad "0.9 was clamped silently"
    write_cfg '{"unfocusedScrim":0.28}'
else
    bad "the split did not take, so the scrim is untested"
fi

echo
echo "Step 5b: focusStyle"
write_cfg '{"focusStyle":"invert"}'; shot 06-invert
look "06-invert.png: the focused footer is filled, and attention is quiet rather than also filled"
write_cfg '{"focusStyle":"frame"}'; shot 07-frame
write_cfg '{"focusStyle":"recede"}'

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
