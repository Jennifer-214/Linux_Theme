# FoxML Theme Hub — root Makefile.
#
# Discovers any directory under src/ that contains its own Makefile and
# recurses into it. To add a new C++ component:
#
#   1. mkdir src/fox-foo/
#   2. drop a Makefile in there exposing `all`, `install`, `clean`
#   3. (nothing here changes)
#
# Usage:
#   make             build everything
#   make install     build + copy binaries to ~/.local/bin
#   make clean       remove build artefacts
#   make test        run unit-test targets in each subdir (skips if absent)

# Auto-detect every src/<tool>/Makefile and turn each directory into a
# sub-target. The shell expansion runs once at Makefile parse time, so
# adding a new src/<tool>/Makefile is picked up on the next `make`.
TOOLS := $(patsubst src/%/Makefile,%,$(wildcard src/*/Makefile))

ifeq ($(TOOLS),)
$(error No src/*/Makefile discovered — is the working tree intact?)
endif

# Without this, `make` picks the FIRST rule defined as the default
# goal — which would be `preflight` below. Pin it to `all` so the
# default invocation actually builds.
.DEFAULT_GOAL := all

all:     preflight $(addprefix build-,$(TOOLS))

# fox-install / fox-vault / fox-render link libcrypto for SHA-256 +
# HMAC. Fail at configure time with a clear hint instead of letting
# the user discover it via a confusing -lcrypto link error. Skipped
# when pkg-config is missing because OpenSSL might still be present.
preflight:
	@if command -v pkg-config >/dev/null 2>&1; then \
		pkg-config --exists libcrypto || { \
			echo "error: libcrypto not found via pkg-config"; \
			echo "       install with: sudo pacman -S openssl"; \
			exit 1; }; \
	fi
.PHONY: preflight
install: $(addprefix install-,$(TOOLS))
clean:   $(addprefix clean-,$(TOOLS))

$(addprefix build-,$(TOOLS)): build-%:
	$(MAKE) --no-print-directory -C src/$* all

$(addprefix install-,$(TOOLS)): install-%:
	$(MAKE) --no-print-directory -C src/$* install

$(addprefix clean-,$(TOOLS)): clean-%:
	$(MAKE) --no-print-directory -C src/$* clean

# `make test` invokes each subdir's `test` target if it has one; subdirs
# without a test target print "no tests" and exit 0 so the umbrella
# target stays green.
test: $(addprefix test-,$(TOOLS))

$(addprefix test-,$(TOOLS)): test-%:
	@if $(MAKE) -n -C src/$* test >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory -C src/$* test; \
	else \
		echo "  - src/$*: no tests"; \
	fi

list:
	@printf "Discovered tools:\n"
	@for t in $(TOOLS); do printf "  - %s\n" "$$t"; done

.PHONY: all install clean test list $(addprefix build-,$(TOOLS)) $(addprefix install-,$(TOOLS)) $(addprefix clean-,$(TOOLS)) $(addprefix test-,$(TOOLS))
