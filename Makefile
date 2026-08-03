SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT     := baia.xcodeproj
SCHEME      := baia
CONFIG      := Debug
DERIVED     := .build
# The product name varies by configuration: `baia-dev.app` out of Debug and
# `baia.app` out of Release, with their own bundle ids and their own directory
# under Application Support. That is what lets the installed copy and the build
# under test run at the same time, so neither takes the other's socket or its
# window list. Derived here rather than written twice.
PRODUCT     := $(if $(filter Release,$(CONFIG)),baia,baia-dev)
APP         := $(DERIVED)/Build/Products/$(CONFIG)/$(PRODUCT).app
BINARY      := $(APP)/Contents/MacOS/$(PRODUCT)
INSTALLED   := /Applications/baia.app
LOG         := $(DERIVED)/xcodebuild.log
# Every local package, discovered rather than listed, so adding one under
# Packages/ needs no edit here and cannot be silently left out of `make test`.
PACKAGES    := $(wildcard Packages/*)
# Files a package embeds into the binary rather than copies beside it. Discovered
# rather than listed, for the reason PACKAGES is: see the guard in `build`.
EMBEDDED    := $(wildcard Packages/*/Sources/*/Resources/*)

.DEFAULT_GOAL := help
# `upstream` is here because a directory of that name exists: without it make
# treats the target as satisfied by the directory and never runs the recipe,
# which looks exactly like a patch that silently stopped being applied.
.PHONY: help doctor bootstrap upstream gen build test run run-attached install uninstall clean distclean

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

doctor: ## Verify the toolchain is usable before anything else
	@ok=0; \
	if ! command -v xcodegen >/dev/null; then \
		echo "MISSING xcodegen        -> make bootstrap"; ok=1; \
	else echo "ok      xcodegen        $$(xcodegen --version 2>&1 | head -1)"; fi; \
	dev=$$(xcode-select -p); \
	if [[ "$$dev" != *Xcode.app* ]]; then \
		echo "WRONG   xcode-select     $$dev"; \
		echo "        xcodebuild needs the full Xcode, not CommandLineTools. Run:"; \
		echo "        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; ok=1; \
	else echo "ok      xcode-select    $$dev"; fi; \
	if command -v xcodebuild >/dev/null && xcodebuild -version >/dev/null 2>&1; then \
		echo "ok      xcodebuild      $$(xcodebuild -version | head -1)"; \
	else echo "MISSING xcodebuild      (fix xcode-select above)"; ok=1; fi; \
	exit $$ok

bootstrap: ## Install build tooling (xcodegen)
	brew install xcodegen

UPSTREAM_DIR := upstream/libghostty-spm
UPSTREAM_REF := $(shell cat upstream/libghostty-spm.ref 2>/dev/null)
UPSTREAM_PATCH := upstream/libghostty-spm-read-text.patch

upstream: ## Recreate the patched libghostty checkout project.yml points at
# `project.yml` pins libghostty by PATH while the read-text change is unmerged,
# and a path pin is machine-local: without this target a fresh clone of baia
# does not build anywhere, with nothing on screen to say why. So the checkout is
# reproducible from two tracked files, the revision and the patch, and never
# from whatever happened to be on one laptop.
#
# The revision is the one SwiftPM had already resolved (1.3.1), so the only
# difference from the unpatched build is the patch itself.
	@if [ -z "$(UPSTREAM_REF)" ]; then \
		echo "missing upstream/libghostty-spm.ref"; exit 1; \
	fi
	@if [ ! -d "$(UPSTREAM_DIR)/.git" ]; then \
		echo "cloning libghostty-spm at $(UPSTREAM_REF)"; \
		rm -rf "$(UPSTREAM_DIR)"; \
		git clone -q --filter=blob:none https://github.com/Lakr233/libghostty-spm "$(UPSTREAM_DIR)"; \
	fi
# Reset before applying, so the target is idempotent: running it twice must not
# fail on an already-applied patch, and must not leave a half-applied one.
	@cd "$(UPSTREAM_DIR)" && \
		git fetch -q origin "$(UPSTREAM_REF)" 2>/dev/null || true; \
		git checkout -q --detach "$(UPSTREAM_REF)" && \
		git reset -q --hard "$(UPSTREAM_REF)" && \
		git clean -qfd
	@cd "$(UPSTREAM_DIR)" && git apply "$(CURDIR)/$(UPSTREAM_PATCH)"
	@echo "patched $(UPSTREAM_DIR) at $(UPSTREAM_REF)"

gen: upstream ## Regenerate baia.xcodeproj from project.yml
	xcodegen generate --spec project.yml

build: gen ## Build Debug. Full log at .build/xcodebuild.log, only errors on stdout
	@mkdir -p $(DERIVED)
	@# A resource a local package carries with `.embedInCode` is not tracked as a
	@# build input. Editing one alone leaves xcodebuild reporting success while
	@# the app ships the previous bytes, which for baia-agent-state.sh means an
	@# installed hook that is not the hook in the tree, and a probe that passes
	@# against a script nobody wrote. Measured 2026-08-01: neither touching a
	@# Swift file in the package nor deleting the generated embedded_resources.swift
	@# dislodges it, and dropping the build directory does, for about ten seconds.
	@for resource in $(EMBEDDED); do \
		if [[ -e "$(APP)" && "$$resource" -nt "$(APP)" ]]; then \
			echo "re-embedding $$resource"; \
			rm -rf $(DERIVED)/Build; \
			break; \
		fi; \
	done
	@# The commit this build came from, passed in as a build setting because no
	@# build setting can run git, and expanded into `BAIAGitCommit` in
	@# Info.plist. `-dirty` counts untracked files as well as modified ones: the
	@# target's `sources` names directories, so a file never added to git still
	@# went into the binary, and everything a build generates is gitignored
	@# already. Computed here rather than in a build phase, which races the task
	@# that processes Info.plist and loses on incremental builds.
	@set +e; \
	commit=$$(git rev-parse --short HEAD 2>/dev/null); \
	if [[ -z "$$commit" ]]; then \
		commit=unknown; \
	elif [[ -n "$$(git status --porcelain 2>/dev/null)" ]]; then \
		commit="$$commit-dirty"; \
	fi; \
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
		BAIA_GIT_COMMIT="$$commit" \
		-quiet \
		build > $(LOG) 2>&1; \
	status=$$?; \
	if [[ $$status -ne 0 ]]; then \
		echo "build failed:"; \
		echo ""; \
		grep -E -A5 "(error:|error;|FAILED|Undefined symbol|Could not resolve)" $(LOG) \
			| head -60 \
			|| tail -40 $(LOG); \
		echo ""; \
		echo "full log: $(LOG)"; \
		exit $$status; \
	fi; \
	echo "built $(APP)"

test: ## Run every local package's tests. No app build, no signing, no Metal
# Every package runs even after one fails, because a single compile error in an
# early package would otherwise hide the state of the six behind it. But the
# failure is remembered and re-raised at the end: a bare `for` loop exits with
# the status of its LAST command, so this target used to answer 0 while a
# package failed to compile, and every agent and script that trusted the exit
# code was making a weaker claim than it believed.
	@failed=""; \
	for pkg in $(PACKAGES); do \
		echo ""; \
		echo "=== $$pkg ==="; \
		swift test --package-path $$pkg || failed="$$failed $$pkg"; \
	done; \
	if [ -n "$$failed" ]; then \
		echo ""; \
		echo "FAILED:$$failed"; \
		exit 1; \
	fi

run: build ## Build and launch detached
	open $(APP)

run-attached: build ## Build and run in the foreground so stdout/stderr land here
	$(BINARY)

install: ## Build Release and install it to /Applications as the copy you use daily
	@# Release rather than Debug, and a separate bundle id and support directory
	@# come with it, so this cannot overwrite or be overwritten by `make run`.
	@$(MAKE) --no-print-directory CONFIG=Release build
	@# Removed rather than copied over. A copy into an existing bundle leaves
	@# whatever the previous version had and the extra file is not in any
	@# manifest, so the next launch mixes two builds with nothing to say so.
	@if [[ -e "$(INSTALLED)" ]]; then \
		echo "replacing $(INSTALLED)"; \
		rm -rf "$(INSTALLED)"; \
	fi
	@cp -R "$(DERIVED)/Build/Products/Release/baia.app" "$(INSTALLED)"
	@echo "installed $(INSTALLED)"
	@echo ""
	@echo "  version:  $$(/usr/bin/defaults read "$(INSTALLED)/Contents/Info" CFBundleShortVersionString)"
	@# The marketing version is a hand-edited constant and cannot say which
	@# source produced this copy; the commit can, and the question "is the
	@# installed build behind main" is asked of this app often enough to have
	@# been answered by mtime before now.
	@echo "  commit:   $$(/usr/bin/defaults read "$(INSTALLED)/Contents/Info" BAIAGitCommit)"
	@echo "  bundle:   $$(/usr/bin/defaults read "$(INSTALLED)/Contents/Info" CFBundleIdentifier)"
	@echo "  state:    ~/Library/Application Support/$$(/usr/bin/defaults read "$(INSTALLED)/Contents/Info" BAIASupportDirectory)"
	@echo ""
	@echo "Notifications are per bundle id: enable baia under System Settings >"
	@echo "Notifications once, the first time you install after an id change."

uninstall: ## Remove the installed copy. Leaves its Application Support directory alone
	@if [[ -e "$(INSTALLED)" ]]; then \
		rm -rf "$(INSTALLED)"; \
		echo "removed $(INSTALLED)"; \
	else \
		echo "$(INSTALLED) is not there"; \
	fi

clean: ## Remove build products, keep resolved packages
	rm -rf $(DERIVED)/Build

distclean: ## Remove everything generated, including the xcodeproj
	rm -rf $(DERIVED) $(PROJECT) $(PACKAGES:%=%/.build)
