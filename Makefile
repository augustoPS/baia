SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT     := baia.xcodeproj
SCHEME      := baia
CONFIG      := Debug
DERIVED     := .build
APP         := $(DERIVED)/Build/Products/$(CONFIG)/baia.app
BINARY      := $(APP)/Contents/MacOS/baia
LOG         := $(DERIVED)/xcodebuild.log

.DEFAULT_GOAL := help
.PHONY: help doctor bootstrap gen build run run-attached clean distclean

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

run: build ## Build and launch detached
	open $(APP)

run-attached: build ## Build and run in the foreground so stdout/stderr land here
	$(BINARY)

clean: ## Remove build products, keep resolved packages
	rm -rf $(DERIVED)/Build

distclean: ## Remove everything generated, including the xcodeproj
	rm -rf $(DERIVED) $(PROJECT)
