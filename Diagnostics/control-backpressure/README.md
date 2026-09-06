# Control backpressure frame eviction

Does a slow reader of a production `ControlTransport` response still see a
complete first frame when outbound-queue eviction runs while that frame is
only partly written? A second client must be answered while the slow reader
is still held. Shutdown, not the probe, must remove the socket file.

The first frame is the largest valid JSON response that still fits the frame
cap, so it cannot hide in a kernel send buffer the way a 20 KiB frame can.
Later queued bytes are invalid `x`-filled frames. The slow socket is created
under a unique owned directory; the probe never unlinks a PID-only path
before bind. Every raw read is bounded.

This compiles `Sources/ControlTransport.swift` and `CLI/ControlClient.swift`
against the PaneControl and WorkspaceLayout packages. It launches no baia app
and removes only the directory it created.

From a terminal outside a baia pane:

    ./Diagnostics/control-backpressure/run.sh
