# Compatibility wrapper for users expecting a top-level make entrypoint.
# Meson remains the authoritative build system for this project.

BUILDDIR := build
MESON := meson

.PHONY: all build setup compile install test check clean dist distcheck uninstall

all: compile

build: compile

setup:
	@if [ ! -d "$(BUILDDIR)" ] || [ ! -f "$(BUILDDIR)/build.ninja" ]; then \
		$(MESON) setup "$(BUILDDIR)"; \
	else \
		$(MESON) setup "$(BUILDDIR)" --reconfigure; \
	fi

compile: setup
	$(MESON) compile -C "$(BUILDDIR)"

install: setup
	$(MESON) install -C "$(BUILDDIR)"

test check: setup
	$(MESON) test -C "$(BUILDDIR)"

clean:
	@if [ -d "$(BUILDDIR)" ] && [ -f "$(BUILDDIR)/build.ninja" ]; then \
		$(MESON) compile -C "$(BUILDDIR)" --clean; \
	fi

dist: setup
	$(MESON) dist -C "$(BUILDDIR)" --include-subprojects --no-tests

distcheck: setup
	$(MESON) dist -C "$(BUILDDIR)" --include-subprojects

uninstall: setup
	@ninja -C "$(BUILDDIR)" uninstall
