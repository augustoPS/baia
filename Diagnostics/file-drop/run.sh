#!/bin/bash
# Run from a terminal outside baia. No daily-driver state is changed.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ISOLATED_LABEL=file-drop
. "$ROOT/Diagnostics/lib/isolated-app.sh"
isolated_refuse_pane
isolated_install_traps
if [ "${BAIA_SKIP_BUILD:-0}" != 1 ]; then
  make -C "$ROOT" build
fi
isolated_prepare
isolated_default_config off
FIXTURE="$ISOLATED_OUT/fixture"
/usr/bin/python3 "$HERE/fixture.py" "$FIXTURE"
/usr/bin/python3 - "$ISOLATED_ZDOT/.zshrc" "$HERE/receiver.py" "$FIXTURE" <<'PY'
from pathlib import Path
import shlex
import sys
Path(sys.argv[1]).write_text("exec /usr/bin/python3 " + shlex.quote(sys.argv[2]) + " " + shlex.quote(sys.argv[3]) + "\n")
PY
export BAIA_FILE_DROP_SELFCHECK_ROOT="$FIXTURE"
isolated_launch
status=0
/usr/bin/python3 - "$FIXTURE" "$ISOLATED_EVIDENCE" <<'PY' || status=$?
import json
from pathlib import Path
import shutil
import sys
import time
root, evidence = map(Path, sys.argv[1:])
names = ["adapter-result.json", "receiver-result.json"]
deadline = time.monotonic() + 20
while time.monotonic() < deadline and not all((root / name).exists() for name in names):
    time.sleep(0.1)
for name in ["manifest.json", "expected-payload.bin", "receiver.ready"] + names:
    if (root / name).exists():
        shutil.copy2(root / name, evidence / name)
for name in names:
    path = root / name
    assert path.exists(), "timed out waiting for " + name
    result = json.loads(path.read_text())
    checks = result.get("checks")
    assert isinstance(checks, dict) and checks, "missing checks: " + name
    assert all(value is True for value in checks.values()), name + ": " + repr(checks)
    print(name + ": " + str(len(checks)) + " checks pass")
PY
isolated_fingerprint_check || status=1
exit "$status"
