# Notification authorization refresh

Compiles `Sources/AttentionNotifier.swift` with a fake UN client and grades
the R12 refresh contract, then compiles a copy with the generation guard
deleted and requires that copy to fail. It does not launch baia, does not
post a notification, and does not change OS permission.

From the repo root, outside a baia pane:

    ./Diagnostics/notification-authorization/run.sh

`run.sh` uses a unique `mktemp` directory (TMPDIR trailing slash stripped) and
removes it on exit. It takes no focus.

## The question

If the user denies notifications, then allows them in System Settings without
relaunching, does the next attention still suppress the banner?

Launch stores the first `requestAuthorization` answer. Activation and turning
the baia setting on reread current UN status. A stale callback from an older
read cannot overwrite a newer one. The first prompt is still asked once.

The stale-read check completes the **newer authorized** callback first and the
**older denied** callback last. Completing FIFO (denied then authorized) still
ends authorized if the generation guard is missing; that is why
`r12-review-control.json` passed both production and the unguarded mutant.
`run.sh` fails the run if that mutant still passes.

`didBecomeActiveNotification` is posted in-process against a notifier that
registered the production observer (`queue: nil`, same thread as AppKit).

## Settings presentation

The Notifications caption shows the effective macOS state as unknown, denied,
or authorized. `AttentionNotifier` publishes a production change notification
only when that state moves; `AppDelegate` refreshes an existing Notifications
page, and a page opened later reads the current value. No DEBUG permission seam
is exposed.

No extra AppDelegate activation hook is required: the notifier observes
`NSApplication.didBecomeActiveNotification` itself, and `isEnabled = true`
after `false` already refreshes. Launch still calls
`requestAuthorizationIfNeeded()` once.

## Coordinator live check

Isolated bundle: deny, permit in System Settings, reactivate, trigger genuine
attention, one banner, no relaunch. Disabled baia setting still suppresses
bounce and banner.
