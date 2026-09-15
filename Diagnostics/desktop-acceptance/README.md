# Desktop acceptance fixture

The bounded, resumable disposable instance the autonomous acceptance plan
drives through the coordinator's desktop tools. It answers one question: is
the app the coordinator is clicking, typing into, and screenshotting a fresh,
uniquely identified copy on scratch state, and does every recorded case
outcome name that exact copy, revision, and evidence? It implements no
desktop input. Clicks, key events, VoiceOver, screenshots, and every semantic
judgment belong to the desktop operator; this fixture only prepares scratch
state, proves readiness, grades the shape of a record, and cleans up exactly
what it created.

Files:

| File | Role |
|---|---|
| `run.sh` | Copies the app through `Diagnostics/lib/isolated-app.sh`, prints `STATE=<fixture.json>`, supervises the copy, answers stop/launch/expect-quit requests, exits on the owned stop marker or a deadline, tears down only its own process and directories |
| `phase.py` | `prepare`, `attention`, `await-quit`, `relaunch`, `record`, `report`, `repair`, `stop` against the printed state path |
| `recorder.py` | Raw-mode stdin recorder for a scratch pane (A02, I01); records bytes as hex with timestamps and restores termios on every exit path |
| `test_phase.py` | No-app negative tests: ownership, process identity, record grading, scenarios, runner protocol, recorder |
| `test_run.sh` | No-app runner checks with a fake bundle: forced prepare failure, interruption, deadline, unexpected exit, expected quit, job ownership, resume |

## Run

The coordinator builds first and runs the fixture from a terminal that is
not a baia pane. The runner never builds when the skip flag is set:

```sh
cd /Users/pasqualotto/Projects/baia
make build
BAIA_ISOLATED_SKIP_BUILD=1 bash Diagnostics/desktop-acceptance/run.sh
```

It prints `STATE=/…/.superpowers/sdd/roadmap/acceptance/<run-id>/fixture.json`
and keeps running. No app is launched yet; the first `prepare` launches it.
The coordinator consumes the printed path as an argument:

```sh
PHASE=/Users/pasqualotto/Projects/baia/Diagnostics/desktop-acceptance/phase.py
STATE=<printed path>
/usr/bin/python3 "$PHASE" --state "$STATE" prepare accessibility
/usr/bin/python3 "$PHASE" --state "$STATE" report
/usr/bin/python3 "$PHASE" --state "$STATE" stop
```

Environment for `run.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `BAIA_DESKTOP_ACCEPTANCE_SKIP_BUILD` / `BAIA_ISOLATED_SKIP_BUILD` | `0` | `1` skips `make build` |
| `BAIA_DESKTOP_ACCEPTANCE_SOURCE_APP` | `.build/Build/Products/Debug/baia-dev.app` | app to copy |
| `BAIA_DESKTOP_ACCEPTANCE_EVIDENCE_ROOT` | `.superpowers/sdd/roadmap/acceptance` | per-run evidence parent |
| `BAIA_DESKTOP_ACCEPTANCE_BATCH_SECONDS` | `900` | deadline renewed by every request (1 through 3600) |
| `BAIA_DESKTOP_ACCEPTANCE_MAX_SECONDS` | `10800` | absolute cap for one runner process |

`run.sh --resume <evidence-dir>` starts a new copy (new run id, new pid, new
bundle id) against an existing evidence directory. The ledger keeps every
case and every fixture run; the previous `fixture.json` is archived beside it.
Use it when a batch timed out or a repair needed a rebuild and the planned
cells (S04) must survive the restart.

Exit codes: `0` after the stop marker, `1` when the copied app exited without
an announced quit or cleanup failed, `124` when a batch or the cap timed out,
`2` for bad arguments, `130`/`143` on SIGINT/SIGTERM. Every non-zero path
still runs the cleanup trap. Interrupt a backgrounded runner with SIGTERM: a
job started with `&` from a non-interactive shell ignores SIGINT and bash
cannot trap an ignored signal.

## Lifecycle contract

- The runner is the only process owner. `phase.py` never signals anything.
  It writes `runner-request.json` in the scratch directory and waits for
  `runner-result.json` with the same request id; a missing or mismatched
  answer within the bound is a failure, never a success. Only `stop`,
  `launch`, and `expect-quit` exist; anything else is refused in the result.
- `prepare <scenario> [--arm <arm>]` requests a stop of the previous copy
  (so its quit-time session write lands before seeding), rewrites the scratch
  session, config, `.zshenv`, project files, and job hook, requests a launch,
  and proves fresh readiness: the pid still runs the copied binary, every
  seeded pane privately reported its capability, `whoami` and `list` answer
  through that pane’s own capability over the socket, and the window server lists one visible layer-0 window
  for that pid. Readiness that does not settle in 45 seconds fails the
  prepare; the app stays up for inspection and the scenario is marked not
  ready in the state.
- An app exit is a failure (runner exit 1) unless announced. `await-quit`
  sends `expect-quit`, then waits for the exact pid to end (A03 Retry, C02
  native quit). `relaunch` starts the same copy again on the session the app
  wrote itself, with no reseeding. Relaunch validates the current schema-2
  groups, each `selectedTab` reference, and every tab's `focusedPane` against
  the pane registrations. It then requires only the exact copied process and
  at least one visible window. It does not require a capability from any
  restored pane. The result names all session panes, the selected pane in each
  group, and a pending activation and per-pane verification statement for
  every pane. A missing or malformed session or reference is refused. Prepare
  keeps the stronger capability, `whoami`, and `list` checks against every
  seeded pane. Any other request clears the expectation.
- Every request renews the batch deadline. A batch with no request for
  `BATCH_SECONDS` ends the runner with 124; the cap ends it regardless.
- Cleanup ends only the recorded pid while its live command is still the
  copied binary (the shared helper's rule), ends recorded foreground jobs only
  while their live start time still matches the recorded one and, while the
  app lives, only when they descend from it, deletes only the marker-owned
  scratch and support directories, and rewrites nothing under the owner's
  config or support. Normal-state fingerprints (config, design overrides,
  Release and Debug sessions and acknowledgements) are saved before the first
  launch and again at teardown as `normal-state-before/after.<run-id>.tsv`.

## Scenarios

Every scenario lands in the run's scratch directory; nothing reads or writes
the owner's config, sessions, or capabilities. `prepare` prints the pane ids,
project paths, seeded files, hashes, and readiness, and writes the same
document to `scenarios/<batch>-<scenario>-<arm>.json` in evidence.

| Scenario | Arms | Scratch state |
|---|---|---|
| `accessibility` | `default`, `feedback` | initialized scratch Git repository `A01-files` with `alpha.txt` and `folder/beta.txt`, one pane, sidebar `files`; `feedback` adds `refuse\x01.txt` to exercise production path refusal |
| `recovery` | `malformed` (default), `malformed-write-refused`, `quit-save-refused` | `malformed`: the exact bytes `{ broken session, preserve me` as `session.json` (hex recorded). `malformed-write-refused`: the same plus support directory 0500 and file 0400 so backup/write is refused until `repair`. `quit-save-refused`: a valid one-pane session; after startup readiness, the same read-only modes so the quit save fails; `repair` restores 0700/0600 for Retry |
| `settings` | `default`, `wrong-type`, `long-root` | opacity 0.42, `#141414`, padding 8. `wrong-type`: `fontSize` is the string `big` beside `windowPadding` 24. `long-root`: a project root name over 160 characters |
| `commands` | `default`, `empty-root` | two groups on two projects with distinct marker text files; `empty-root` seeds no project roots |
| `windows` | `default` | two groups with two tabs each, four panes; logical ids in `logical` |
| `busy-close` | `busy`, `idle` | one leaf tab plus one split tab (three panes). `busy` arms a `.zshrc` hook: every new shell runs a foreground `sleep 300` and records `pid`, `started`, `shell`, `pane` in `jobs/sleep-<shell>.job`; `report` lists each job with liveness by start identity |
| `input` | `default` | one pane, `optionAsAlt` on, a paste source with a harmless `echo MARKER-NOT-RUN` line |

`attention [--pane <id>] --state-value blocked --label <text>` sends a pane
report through that pane's own capability and waits for effective attention
`asking` with the spent sequence; `--release` clears it. It records the wire
response and the pane record, never the capability.

## Raw stdin recorder (A02, I01)

Create the `<evidence>/recorder` parent directory first. Run inside the target scratch pane before any approval or key-event case:

```sh
/usr/bin/python3 /Users/pasqualotto/Projects/baia/Diagnostics/desktop-acceptance/recorder.py \
  --out <evidence>/recorder/<case-label> --seconds 600 --label <case-label>
```

The pane's shell is in raw mode from then on. Every byte the pane delivers
is appended to `bytes.jsonl` as `{"at", "hex", "len"}` and echoed sanitized
(`<0D>`, `<1B>`, printable ASCII as-is) so a screenshot agrees with the file.
`meta.json` names the pid, `BAIA_PANE`, tty, and start time, which is how the
operator proves the receiving pane before sending anything. It ends on the
`stop` file in `--out`, the deadline, three consecutive Ctrl-D bytes, or
SIGTERM/SIGHUP, restores the saved termios with `TCSANOW`, and writes
`summary.json` with byte, CR (`0x0D`), and ESC (`0x1B`) counts and
`termiosRestored`. Approval Return and denial Escape therefore arrive as
bytes in the log, never as shell input.

## Records and the ledger

`record --case <id> --result-file <path>` imports one reviewed observation.
The result file must be JSON inside this run's evidence directory:

```json
{
  "version": 1, "case": "A02", "result": "PASS",
  "fixtureRunId": "…", "pid": 12345, "binarySha256": "…", "gitRevision": "…",
  "scenario": "accessibility",
  "setup": "…", "expected": "…", "observed": "…",
  "actions": [{"at": 1789000000.0, "action": "VO-Space on Approve"}],
  "verifiedBy": ["terminal-bytes", "caption"],
  "evidence": [{"path": "<evidence>/captures/a02.mov", "kind": "video", "judgment": "…"}],
  "restoration": {"required": true, "verified": true, "readback": "VoiceOver off"},
  "cleanup": "…",
  "missingCapability": "only for BLOCKED"
}
```

The grader refuses, without touching the ledger: another case id, run id,
pid, binary hash, git revision, or scenario than the live fixture; a result
file or evidence path outside the evidence directory, including symlink
escapes; missing or empty evidence files; a screenshot, video, or frame set
without a semantic judgment; a PASS with no evidence, no timestamped action,
required-but-unverified restoration, changed normal-state fingerprints, or a
dead fixture process; a PASS whose only verification is `input-delivered`,
`api-success`, or `ax-press-returned`; a BLOCKED result without a named
capability; and any document carrying a `token`, `capability`, or `secret`
key. Accepted records land in `ledger.json` under `cases.<id>.latest` and
`.history`, with file hashes, the normal-state comparison, and the fixture
run. The grader validates records, not visual truth: the desktop operator
inspects the original captures before assigning a result.

`report` prints the safe identity: run id, git revision and dirty count,
bundle id, app and binary paths and hashes, pid and whether it is still the
copied binary, visible windows, scratch, support, session, config, socket and
evidence paths, the current scenario, recorded jobs, the normal-state
comparison, and the per-case ledger summary. It never reads the token
directory and omits it from the output.

## No-app checks

Nothing here builds or launches baia:

```sh
cd /Users/pasqualotto/Projects/baia
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest -v Diagnostics/desktop-acceptance/test_phase.py
bash Diagnostics/desktop-acceptance/test_run.sh
/bin/bash -n Diagnostics/desktop-acceptance/run.sh
```

`test_run.sh` copies a fake bundle whose executable blocks on a fifo and
presents its own path as its command, so the shared helper's exact-pid rules
apply to it as to a real copy. It takes about 30 seconds.

## Limitations

- Prepare readiness proves a live pid, socket, every seeded pane's capability,
  exact `whoami` and `list` responses, and a visible window. It does not prove
  that a window has focus or that any pane is the first responder; the operator
  verifies the receiving pane through recorder metadata or `baia whoami`
  before typing.
- After relaunch, no restored pane capability is considered ready before
  native activation. This includes a tab saved as selected and visibly
  restored as selected. Relaunch proves only valid schema-2 session references,
  exact process identity, and a visible window. Its `pendingPaneVerification`
  map marks every session pane pending. The operator must activate each native
  tab, then verify that pane's fresh capability and exact `whoami` response.
- The recorder restores termios itself. If the pane's shell is killed with
  the recorder still raw, the pane is gone with it; nothing outside the pane
  changes.
- Foreground-job cleanup recognises only the fixture's own `sleep 300` hook
  records. Jobs the operator starts by hand are not the fixture's to end.
- `expect-quit` is one announcement for the next exit. A second exit without
  a new announcement ends the runner with 1.
- The window census uses `CGWindowListCopyWindowInfo` through `osascript`;
  it needs the Screen Recording grant the plan already recorded, and lists
  layer-0 onscreen windows only.
