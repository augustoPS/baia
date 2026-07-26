# Upstream patches

Changes baia needs in `Lakr233/libghostty-spm`, kept here as patches until they
are merged upstream. The standing decision is to depend on upstream rather than
fork, so anything in this directory is a pull request that has not landed yet,
not a private divergence.

Apply to a checkout with `git apply`, or pin a branch carrying it in
`project.yml` while the PR is in flight.

## `libghostty-spm-read-text.patch`

Exposes the terminal's text to the host. `ghostty_surface_read_text` and the
`ghostty_point_tag_e` scopes have been in the C API all along; the Swift wrapper
surfaced them only as `InMemoryTerminalSession.readViewportText()`, hardcoded to
`GHOSTTY_POINT_VIEWPORT` and reachable only from the host-managed backend.
`TerminalSurface.surface` is private, so an `.exec` host has no route to the text
at all.

That single gap is what made find-in-pane look unbuildable. It is not a ghostty
limitation and it does not need host-managed IO.

Adds two things:

- `TerminalSurface.readText(scope:)` plus `AppTerminalView.readScreenText()`,
  over `GHOSTTY_POINT_SCREEN`, which covers scrollback rather than only the
  visible rows.
- `TerminalSurface.readRow(_:columns:)` plus its view wrapper, over
  `GHOSTTY_POINT_COORD_EXACT`, which reads one screen row.

Both are needed, because they answer different questions. Measured against a
144-column pane holding a 500-character line:

- The whole-screen read returns **logical** lines. The 500 characters come back
  as one string line, so a match is never split by a soft wrap.
- The per-row read returns **screen** rows. The same 500 characters come back as
  four rows of 144, 144, 144 and 68.

So line index is not row index, and `scrollToRow`, which is already public and
takes an absolute scrollback row, cannot be fed from the whole-screen read
directly. Matching uses the cheap whole read; resolving a match to a row for
navigation uses exact reads, bounded to the matches the user actually visits.
Deriving the row arithmetically from line lengths would work for ASCII and drift
on wide characters and tabs, which is why the exact read is worth having.

`ghostty_text_s` carries only `text` and `text_len`, so there is no row metadata
to ask for instead.
