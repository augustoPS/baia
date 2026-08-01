#!/usr/bin/env python3
"""Checks executor briefs against the two things a brief can get wrong mechanically.

    check.py --repo <root> --settings <executor-settings.json> <brief.md> [...]

Prints one line per brief and exits non-zero if any failed.

**Rule 1, verification reach.** A brief that permits changes to a package the app
target imports must verify with a command that compiles the app target.

Not a heuristic. `Sources/` imports eleven of the local packages, so a change to
any of them can break the app target at compile time, and a brief is written
before the change exists: it cannot know whether the edit will be source
breaking. `make test` never compiles `Sources/`, so a brief pairing a package
change with `make test` alone has no way to find out. That is exactly what
happened on 2026-08-01, where a non-defaulted parameter added to a public
initializer broke four call sites and every test stayed green.

**Rule 2, allowlist agreement.** Every command a brief's Verify section names must
be permitted by the executors' own settings file, in both its bare and its
rtk-prefixed spelling.

Both, because neither covers the other. `rtk hook claude` runs first in the
PreToolUse chain and rewrites the command, so every hook after it reads
`rtk make build`; permission rules are matched before the rewrite and still want
the bare form. A brief naming a command the executor cannot run halts a pane on a
prompt, which is how the 2026-08-01 run spent four hours doing nothing.

**What this cannot do.** It reads what a brief writes down. A brief that silently
omits the package it will change gets through, and so does one whose scope is
coherent and whose goal is out of reach for a reason no static rule can see. The
third 2026-08-01 defect, a prune keyed on the raw working directory where the
surface keys on the resolved anchor, is invisible here and would be invisible to
any check that does not run the code.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Commands that compile the app target. `make run` and `make run-attached` also
# would, and are absent on purpose: they launch a second baia and every executor
# denies them, so naming one in a brief is a different fault than this rule's.
APP_COMPILING = ("make build", "xcodebuild")

# The leading token of something that is a command rather than a symbol. Verify
# sections hold both: "`make test` from the worktree root" is one of each.
COMMAND_HEADS = ("make", "swift", "xcodebuild", "./", "bash", "python3")


def app_imported_packages(repo: Path) -> set[str]:
    """Local packages that `Sources/` imports, which is where rule 1 gets its bite."""
    packages = {entry.name for entry in (repo / "Packages").iterdir() if entry.is_dir()}
    imported = set()
    for swift in (repo / "Sources").rglob("*.swift"):
        for line in swift.read_text(encoding="utf-8", errors="replace").splitlines():
            match = re.match(r"^import\s+([A-Za-z_][A-Za-z0-9_]*)", line)
            if match and match.group(1) in packages:
                imported.add(match.group(1))
    return imported


def packages_named(text: str, packages: set[str]) -> set[str]:
    """Packages a brief names, in either spelling it uses.

    `Packages/GitWorkspace/Sources/...` is the unambiguous form. A bare backticked
    `GitWorkspace` is included too, because a brief that says its fix runs "through
    `GitWorkspace`" is naming the same thing in prose, and on 2026-08-01 one brief
    used both spellings and another used only the second.
    """
    named = set(re.findall(r"Packages/([A-Za-z_][A-Za-z0-9_]*)", text)) & packages
    named |= {token for token in re.findall(r"`([A-Za-z_][A-Za-z0-9_]*)`", text)
              if token in packages}
    return named


def verify_commands(text: str) -> list[str]:
    """The commands under `## Verify`, read out of its backticked spans."""
    section = re.search(r"^##+\s*Verify\s*$(.*?)(?=^##+\s|\Z)", text,
                        re.MULTILINE | re.DOTALL)
    if not section:
        return []
    found = []
    for span in re.findall(r"`([^`]+)`", section.group(1)):
        span = span.strip()
        if span.startswith(COMMAND_HEADS) and span not in found:
            found.append(span)
    return found


def permits(rules: list[str], command: str) -> bool:
    """Whether a `Bash(...)` rule list covers `command`.

    `Bash(X)` is exact and `Bash(X:*)` is a prefix, which is the harness's own
    reading of the two forms.
    """
    for rule in rules:
        match = re.fullmatch(r"Bash\((.*)\)", rule)
        if not match:
            continue
        pattern = match.group(1)
        if pattern.endswith(":*"):
            prefix = pattern[:-2]
            if command == prefix or command.startswith(prefix + " "):
                return True
        elif pattern.endswith("*"):
            if command.startswith(pattern[:-1]):
                return True
        elif command == pattern:
            return True
    return False


def check(brief: Path, imported: set[str], packages: set[str],
          allow: list[str], deny: list[str]) -> list[str]:
    text = brief.read_text(encoding="utf-8")
    faults = []

    commands = verify_commands(text)
    if not commands:
        return ["names no verification command under `## Verify`, so nothing says "
                "what would show the work was done"]

    named = packages_named(text, packages) & imported
    if named and not any(command.startswith(APP_COMPILING) for command in commands):
        faults.append(
            "changes {}, which `Sources/` imports, and verifies with {}. None of "
            "those compile the app target, so a source-breaking change there is "
            "invisible to everything the executor is allowed to run. Add "
            "`make build` to Verify and widen Scope to match it.".format(
                ", ".join(sorted(named)),
                ", ".join("`%s`" % command for command in commands),
            )
        )

    for command in commands:
        for spelling in (command, "rtk " + command):
            if permits(deny, spelling):
                faults.append("Verify names `%s`, which the executors deny as `%s`"
                              % (command, spelling))
            elif not permits(allow, spelling):
                faults.append(
                    "Verify names `%s` and the executors do not permit `%s`, so the "
                    "pane halts on a prompt. Permission rules match before "
                    "`rtk hook claude` rewrites the command and later hooks read it "
                    "after, so both spellings need a rule." % (command, spelling)
                )

    return faults


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--settings", required=True, type=Path)
    parser.add_argument("briefs", nargs="+", type=Path)
    args = parser.parse_args()

    settings = json.loads(args.settings.read_text(encoding="utf-8"))
    permissions = settings.get("permissions", {})
    allow = permissions.get("allow", [])
    deny = permissions.get("deny", [])

    packages = {entry.name for entry in (args.repo / "Packages").iterdir() if entry.is_dir()}
    imported = app_imported_packages(args.repo)

    failed = 0
    for brief in sorted(args.briefs):
        faults = check(brief, imported, packages, allow, deny)
        if faults:
            failed += 1
            print("FAIL  %s" % brief.name)
            for fault in faults:
                print("        %s" % fault)
        else:
            print("ok    %s" % brief.name)

    print()
    print("  %d brief(s) checked, %d failed" % (len(args.briefs), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
