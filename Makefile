# Compatibility wrapper for users expecting a top-level make entrypoint.
# Meson remains the authoritative build system for this project.

BUILDDIR := build
MESON := $(or $(wildcard /usr/bin/meson),$(wildcard /usr/local/bin/meson),meson)
NINJA := ninja

SMART ?= 1
# By default, keep install plain so `sudo make install` does not depend on smart tooling.
SMART_INSTALL ?= 0
# 0 means unlimited retries.
SMART_MAX_RETRIES ?= 0
SMART_LOG ?= /tmp/vte-smart-build.log
SMART_APT_UPDATE ?= 1

.PHONY: all build setup reconfigure compile compile-plain install install-plain \
	test test-plain check clean dist distcheck uninstall __smart_internal

all: compile

build: compile

setup:
	@if ! command -v "$(NINJA)" >/dev/null 2>&1; then \
		echo "ninja is required to build this project"; \
		exit 1; \
	elif [ ! -d "$(BUILDDIR)" ] || [ ! -f "$(BUILDDIR)/build.ninja" ]; then \
		"$(MESON)" setup "$(BUILDDIR)"; \
	else \
		"$(MESON)" setup "$(BUILDDIR)" --reconfigure; \
	fi

reconfigure:
	@if [ ! -d "$(BUILDDIR)" ] || [ ! -f "$(BUILDDIR)/build.ninja" ]; then \
		"$(MESON)" setup "$(BUILDDIR)"; \
	else \
		"$(MESON)" setup "$(BUILDDIR)" --reconfigure; \
	fi

compile:
	@if [ "$(SMART)" != "0" ] && [ -z "$(SMART_INTERNAL)" ]; then \
		$(MAKE) SMART=0 SMART_INTERNAL=1 __smart_internal SMART_TARGETS="compile-plain"; \
	else \
		$(MAKE) SMART=0 compile-plain; \
	fi

compile-plain: setup
	$(NINJA) -C "$(BUILDDIR)"

install:
	@if [ "$(SMART_INSTALL)" != "0" ] && [ "$(SMART)" != "0" ] && [ -z "$(SMART_INTERNAL)" ]; then \
		$(MAKE) SMART=0 SMART_INTERNAL=1 __smart_internal SMART_TARGETS="install-plain"; \
	else \
		$(MAKE) SMART=0 install-plain; \
	fi

install-plain: setup
	$(NINJA) -C "$(BUILDDIR)" install

test check:
	@if [ "$(SMART)" != "0" ] && [ -z "$(SMART_INTERNAL)" ]; then \
		$(MAKE) SMART=0 SMART_INTERNAL=1 __smart_internal SMART_TARGETS="test-plain"; \
	else \
		$(MAKE) SMART=0 test-plain; \
	fi

test-plain: setup
	$(NINJA) -C "$(BUILDDIR)" test

clean:
	@if [ -d "$(BUILDDIR)" ] && [ -f "$(BUILDDIR)/build.ninja" ]; then \
		$(NINJA) -C "$(BUILDDIR)" clean; \
	fi

dist: setup
	"$(MESON)" dist -C "$(BUILDDIR)" --include-subprojects --no-tests

distcheck: setup
	"$(MESON)" dist -C "$(BUILDDIR)" --include-subprojects

uninstall: setup
	@$(NINJA) -C "$(BUILDDIR)" uninstall

__smart_internal:
	@set -eu; \
	smart_targets="$(SMART_TARGETS)"; \
	if [ -z "$$smart_targets" ]; then smart_targets="compile-plain"; fi; \
	smart_tool="$${SMART_TOOL:-}"; \
	if [ -z "$$smart_tool" ] && command -v smart >/dev/null 2>&1; then \
		smart_tool="$$(command -v smart)"; \
        elif [ -x "$$HOME/bin/smart" ]; then \
		smart_tool="$$HOME/bin/smart"; \
	elif [ -z "$$smart_tool" ]; then \
		echo "smart-build-debian not found (set SMART_TOOL=/path/to/smart)"; \
		exit 127; \
	fi; \
	"$$smart_tool" --name vte --log "$(SMART_LOG)" --max-retries "$(SMART_MAX_RETRIES)" --apt-update "$(SMART_APT_UPDATE)" -- $(MAKE) SMART=0 $$smart_targets
