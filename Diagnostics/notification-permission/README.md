# Notification permission and delivery fixture

This fixture supplies the remaining live gate for R12. It raises real
`blocked` attention through one pane's own control capability and records the
wire response plus the pane's effective attention. The optional `delivered`
phase asks the same copied process for its own `UNUserNotificationCenter`
delivered history (identifier, body, delivery date). It does not inspect or
claim a macOS banner or Notification Center UI; the coordinator still owns
those observations through Computer Use.

The runner uses `Diagnostics/lib/isolated-app.sh`. It creates a unique bundle,
executable, support directory, config, shell environment, token directory,
schema-2 session, pane, and project. Only the call to `isolated_prepare` receives
`TMPDIR=/Users/pasqualotto/Applications`, the location proven to receive the
macOS permission prompt. The copy is registered before direct launch and
unregistered during exact-PID cleanup. Normal configuration, Release/Debug
sessions, and acknowledgement files are fingerprinted by the shared helper;
the fixture never reads normal capabilities or session contents.

## Run

The coordinator must build first and run this from a non-baia terminal. The
fixture itself never builds:

```sh
cd /Users/pasqualotto/Projects/baia
Diagnostics/notification-permission/run.sh
```

Copy the printed `STATE=...` path into a second terminal:

```sh
PHASE=/Users/pasqualotto/Projects/baia/Diagnostics/notification-permission/phase.py
STATE=/private/tmp/baia-notification-permission-evidence.XXXXXX/fixture.json
/usr/bin/python3 "$PHASE" --state "$STATE" report
```

The runner waits up to 30 minutes by default, checks that its exact copied
process remains alive, and exits when the `stop` phase creates its owned marker.
Set `BAIA_NOTIFICATION_PERMISSION_HOLD_SECONDS` from 60 through 3600 when a
different bounded observation window is needed.

## Coordinator phases

Before `trigger` or `release-new`, move the copied app behind another app. The
phase refuses to raise attention while the copied PID is frontmost.

1. With the desired macOS permission state already visible, background the app
   and raise the first waiting report:

   ```sh
   /usr/bin/python3 "$PHASE" --state "$STATE" trigger --label denied-first
   /usr/bin/python3 "$PHASE" --state "$STATE" delivered --label denied-first
   ```

2. Change permission through System Settings. Activate the same copied PID once
   so `AttentionNotifier` refreshes, background it again, then clear and raise a
   new edge:

   ```sh
   /usr/bin/python3 "$PHASE" --state "$STATE" release-new --label authorized-after-refresh
   /usr/bin/python3 "$PHASE" --state "$STATE" delivered --label authorized-after-refresh
   ```

3. Disable the disposable notification preference, wait for its control-channel
   propagation fence, then raise a fresh edge while the app stays backgrounded:

   ```sh
   /usr/bin/python3 "$PHASE" --state "$STATE" notifications off
   /usr/bin/python3 "$PHASE" --state "$STATE" release-new --label disabled-preference
   /usr/bin/python3 "$PHASE" --state "$STATE" delivered --label disabled-preference
   ```

4. Re-enable it and raise one more edge after reauthorization:

   ```sh
   /usr/bin/python3 "$PHASE" --state "$STATE" notifications on
   /usr/bin/python3 "$PHASE" --state "$STATE" release-new --label enabled-after-reauthorization
   /usr/bin/python3 "$PHASE" --state "$STATE" delivered --label enabled-after-reauthorization
   ```

Each settings phase briefly closes the disposable control channel and waits for
the wire to answer `disabled`, then reopens it with the requested notification
value unchanged and waits for `ok`. That is a production settings-reload fence,
not a fixed-delay guess. Each action also verifies the recorded PID still names
the copied executable. A single report has a 1,800-second app-enforced TTL; the
runner's outer pause is separately bounded.

Use `snapshot` to record another pane reading without raising attention, and
print or stop the run with:

```sh
/usr/bin/python3 "$PHASE" --state "$STATE" snapshot --label duplicate-count-observed-externally
/usr/bin/python3 "$PHASE" --state "$STATE" report
/usr/bin/python3 "$PHASE" --state "$STATE" stop
```

The report's `deliveryClaim` remains `external-verification-required`. A
`delivered` phase records only this copy's delivered notification identifiers,
bodies, dates, and the fixture PID. Passing the fixture means the report was
accepted, effective attention became `asking`, setting propagation completed,
every phase stayed on one PID, cleanup removed only the copied instance, and
the coordinator separately recorded the actual banner/list counts. macOS
delivery latency is measured in that live run; this fixture makes no universal
one-second promise.

## No-app checks

These checks do not build or launch baia:

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest -v \
  Diagnostics/notification-permission/test_phase.py
/bin/bash -n Diagnostics/notification-permission/run.sh
```
