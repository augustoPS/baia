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
.PHONY: help doctor bootstrap gen build test run run-attached clean distclean

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

gen: ## Regenerate baia.xcodeproj from project.yml
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
