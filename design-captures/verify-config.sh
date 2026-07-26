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
    screencapture -x -o -R"$x,$y,$w,$h" "$OUT/$1.png" && echo "        wrote $OUT/$1.png"
}

# Reads one pixel well inside the terminal area, above the 22 pt footer and clear
# of the padding, and prints it as #rrggbb.
pixel() {
    local geom x y w h px py
    geom=$(osascript -e 'tell application "System Events" to tell process "baia" to get {position, size} of window 1' 2>/dev/null) || return 1
    x=$(echo "$geom"|cut -d, -f1|tr -d ' '); y=$(echo "$geom"|cut -d, -f2|tr -d ' ')
    w=$(echo "$geom"|cut -d, -f3|tr -d ' '); h=$(echo "$geom"|cut -d, -f4|tr -d ' ')
    px=$((x + w - 60)); py=$((y + h - 120))
    screencapture -x -o -R"$px,$py,2,2" "$OUT/.probe.png" 2>/dev/null || return 1
    python3 - "$OUT/.probe.png" <<'PY'
import sys, subprocess, tempfile, os
src = sys.argv[1]
raw = tempfile.mktemp(suffix=".txt")
# sips cannot print a pixel, so go through a 1x1 BMP-ish route: use Python's
# built-in PNG decode via `sips` conversion to TIFF then read the first pixel.
subprocess.run(["sips","-s","format","png","-z","1","1",src,"--out",src+".1.png"],
               capture_output=True)
data = open(src+".1.png","rb").read()
import zlib, struct
# minimal PNG reader for a 1x1 truecolour image
pos = 8; idat = b""; depth = None; ctype = None
while pos < len(data):
    ln = struct.unpack(">I", data[pos:pos+4])[0]; typ = data[pos+4:pos+8]
    chunk = data[pos+8:pos+8+ln]
    if typ == b"IHDR":
        _, _, depth, ctype = struct.unpack(">IIBB", chunk[:10])
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + ln
buf = zlib.decompress(idat)
px = buf[1:]  # skip the filter byte of the single row
if ctype == 6: r,g,b = px[0],px[1],px[2]
elif ctype == 2: r,g,b = px[0],px[1],px[2]
else: r=g=b=px[0]
print("#%02x%02x%02x" % (r,g,b))
os.remove(src+".1.png")
PY
}

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
bg=$(pixel)
echo "        terminal background reads $bg"
case "$bg" in
    "#141414"|"#131313"|"#151515") ok "background is #141414, so the theme layer did not overwrite it" ;;
    "#000000") bad "background is pure black: backgroundHex was overridden by the theme (render-order bug)" ;;
    *) look "background reads $bg; opacity 0.85 over a wallpaper shifts this, compare against ghostty by eye" ;;
esac
shot 01-defaults
look "01-defaults.png: font 11.5, padding 8, blur, transparent titlebar, block cursor"

echo
echo "Step 3: a live theme change moves surface and chrome together, losing nothing"
type_line "sleep 300"
shot 02-before-theme
write_cfg '{"themeName":"Solarized Light"}'
sleep 2
shot 03-after-theme
[ "$(shells)" -ge 1 ] && ok "the shell survived the theme change (no surface respawn)" || bad "the pty died: something assigned view.configuration"
look "02 vs 03: the surface AND every footer moved, and 'sleep 300' is still on screen"

echo
echo "Step 4: the decoder clamps and says so"
write_cfg '{"themeName":"Dark Pastel","unfocusedScrim":0.9}'
grep -q "unfocusedScrim" "$LOG" && ok "the clamp was reported on stderr" || bad "0.9 was clamped silently"
write_cfg '{"unfocusedScrim":0}'; shot 04-scrim-off
write_cfg '{"unfocusedScrim":0.34}'; shot 05-scrim-max
look "04 vs 05: the unfocused panes darken, the focused one does not"

echo
echo "Step 5: focusStyle"
write_cfg '{"focusStyle":"invert"}'; shot 06-invert
look "06-invert.png: the focused footer is filled, and attention is quiet rather than also filled"
write_cfg '{"focusStyle":"frame"}'; shot 07-frame
write_cfg '{"focusStyle":"recede"}'

echo
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
