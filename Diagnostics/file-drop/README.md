# File drop integration probe

Run `./Diagnostics/file-drop/run.sh` from a terminal outside Baia. It builds
Debug first. Set `BAIA_SKIP_BUILD=1` only after building the current source.

The probe copies Debug into a disposable app with its own bundle identity,
support directory, configuration and shell fixture. It creates two small PNGs
with spaces, quotes, a dollar sign, a backtick and Unicode in their names.

The DEBUG self-check calls the installed terminal drop view's drag entry,
update, preparation and perform methods with a real pasteboard and a synthetic
dragging-info object. A receiver in the real terminal PTY compares the exact
inserted bytes against independently quoted paths. It checks order, absence of
Enter, readable PNG files and their SHA-256 hashes. Adapter and receiver results
are retained in the printed evidence directory. Normal config and session
fingerprints are checked before cleanup. Cleanup signals only this run's app.

This does not reproduce a physical Finder gesture or test whether a particular
agent CLI opens the images and sends their pixels to a model. It verifies the
app adapter and terminal transport to a process that can open the files.

Run `/usr/bin/python3 Diagnostics/file-drop/test_receiver.py` to check the
receiver alone. Its negative controls append Enter and replace an image after
the manifest is written. Both must fail the relevant checks.
