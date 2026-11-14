# Linux_Theme — root Makefile.
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

# desk-install / desk-vault / desk-render / desk-drawer link libcrypto for SHA-256 +
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

# Tools that link ../desk-intel/libdesk-intel.a build after it. Each one's sub-make (FORCE'd, so a stale
# library is rebuilt) would otherwise rebuild the same archive at the same moment under -j — install.sh
# runs `make -j install` — and collide. Discovered like TOOLS: any Makefile naming the library.
INTEL_USERS := $(filter-out desk-intel,$(patsubst src/%/Makefile,%,$(shell grep -l 'libdesk-intel\.a' src/*/Makefile)))
$(addprefix build-,$(INTEL_USERS)): build-desk-intel
$(addprefix install-,$(INTEL_USERS)): install-desk-intel
# The same for ../desk-common/libdesk-common.a, which most tools link and rebuild when it is missing or stale.
COMMON_USERS := $(filter-out desk-common,$(patsubst src/%/Makefile,%,$(shell grep -l 'libdesk-common\.a' src/*/Makefile)))
$(addprefix build-,$(COMMON_USERS)): build-desk-common
$(addprefix install-,$(COMMON_USERS)): install-desk-common

$(addprefix install-,$(TOOLS)): install-%:
	$(MAKE) --no-print-directory -C src/$* install

$(addprefix clean-,$(TOOLS)): clean-%:
	$(MAKE) --no-print-directory -C src/$* clean

# `make test` invokes each subdir's `test` target if it has one; subdirs
# without a test target print "no tests" and exit 0 so the umbrella
# target stays green.
test: $(addprefix test-,$(TOOLS)) test-scripts

# Only the tests that name what changed since the last commit; says so when files moved under the run.
test-fast:
	@python3 -B tests/run_changed.py

# Required release check: missing Claude/TypeScript/engine types are failures, never skips.
test-claude: build-desk-render
	@FOXML_REQUIRE_MOD_CHECKS=1 python3 -B tests/test_claude_mod.py

test-work-integrations:
	@python3 -B tests/run_work_checks.py

# Python script tests (shared/bin tools without their own src/<tool>/ dir).
test-scripts:
	@for t in tests/test_*.py; do [ -e "$$t" ] || continue; echo "  - $$t"; python3 "$$t" || exit 1; done

$(addprefix test-,$(TOOLS)): test-%:
	@if $(MAKE) -n -C src/$* test >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory -C src/$* test; \
	else \
		echo "  - src/$*: no tests"; \
	fi

list:
	@printf "Discovered tools:\n"
	@for t in $(TOOLS); do printf "  - %s\n" "$$t"; done

.PHONY: all install clean test test-fast test-claude test-work-integrations list $(addprefix build-,$(TOOLS)) $(addprefix install-,$(TOOLS)) $(addprefix clean-,$(TOOLS)) $(addprefix test-,$(TOOLS))
