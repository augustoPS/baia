SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT     := baia.xcodeproj
SCHEME      := baia
CONFIG      := Debug
DERIVED     := .build
APP         := $(DERIVED)/Build/Products/$(CONFIG)/baia.app
BINARY      := $(APP)/Contents/MacOS/baia
LOG         := $(DERIVED)/xcodebuild.log
# Every local package, discovered rather than listed, so adding one under
# Packages/ needs no edit here and cannot be silently left out of `make test`.
PACKAGES    := $(wildcard Packages/*)

.DEFAULT_GOAL := help
# `upstream` is here because a directory of that name exists: without it make
# treats the target as satisfied by the directory and never runs the recipe,
# which looks exactly like a patch that silently stopped being applied.
.PHONY: help doctor bootstrap upstream gen build test run run-attached clean distclean

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
	@set +e; \
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) \
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

clean: ## Remove build products, keep resolved packages
	rm -rf $(DERIVED)/Build

distclean: ## Remove everything generated, including the xcodeproj
	rm -rf $(DERIVED) $(PROJECT) $(PACKAGES:%=%/.build)
