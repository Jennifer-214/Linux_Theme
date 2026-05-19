# src/fox-install/Makefile — C++ orchestrator.
#
# Every .cpp under core/ and modules/ is compiled and linked into one
# binary. To add a new module, drop a .cpp into modules/ and add one
# line to core/modules.def — no Makefile changes needed.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

# Shared core library — produces libfox-common.a (ui/shell helpers, and
# in future slices the dispatcher). Linked into our binary.
FOX_COMMON_DIR := ../fox-common
FOX_COMMON_LIB := $(FOX_COMMON_DIR)/libfox-common.a

CORE_SRC    := $(wildcard core/*.cpp)
MODULE_SRC  := $(wildcard modules/*.cpp)
MAIN_SRC    := fox-install.cpp

CORE_OBJ    := $(CORE_SRC:.cpp=.o)
MODULE_OBJ  := $(MODULE_SRC:.cpp=.o)
MAIN_OBJ    := $(MAIN_SRC:.cpp=.o)

BIN := fox-install

all: $(BIN)

$(BIN): $(MAIN_OBJ) $(CORE_OBJ) $(MODULE_OBJ) $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -o $@ $(MAIN_OBJ) $(CORE_OBJ) $(MODULE_OBJ) -L$(FOX_COMMON_DIR) -lfox-common -lcrypto

# Ensure libfox-common.a is built before linking.
$(FOX_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(FOX_COMMON_DIR)

# Generic rule covers everything; registry.cpp picks up modules.def
# automatically via #include in registry.cpp.
%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Header dependency: anything that includes core/module.hpp pulls in
# core/modules.def transitively. Re-tag registry.cpp explicitly so a
# modules.def edit triggers a rebuild.
core/registry.o: core/registry.cpp core/module.hpp core/modules.def

install: all
	@mkdir -p $(PREFIX)
	@install -m 755 $(BIN) $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"
	@# Record the source repo path so the installed binary can find
	@# templates/ + themes/ when invoked from outside the repo.
	@mkdir -p $(HOME)/.local/share/foxml
	@cd ../.. && pwd > $(HOME)/.local/share/foxml/repo-dir
	@echo "  + repo path recorded: $$(cat $(HOME)/.local/share/foxml/repo-dir)"

test: tests/test_registry tests/test_state_manifest tests/test_classifier tests/test_state_checks tests/test_conflict_resolve tests/test_wizard tests/test_install_lock
	@./tests/test_registry
	@./tests/test_state_manifest
	@./tests/test_classifier
	@./tests/test_state_checks
	@./tests/test_conflict_resolve
	@./tests/test_wizard
	@./tests/test_install_lock

# Test binary links only core/registry.o (the X-macro table); modules
# are stubbed inside the test file so we don't drag in their real
# implementations.
tests/test_registry: tests/test_registry.cpp core/registry.o
	$(CXX) $(CXXFLAGS) tests/test_registry.cpp core/registry.o -o $@

tests/test_state_manifest: tests/test_state_manifest.cpp core/state_manifest.o
	$(CXX) $(CXXFLAGS) tests/test_state_manifest.cpp core/state_manifest.o -o $@ -lcrypto

tests/test_classifier: tests/test_classifier.cpp core/classifier.o
	$(CXX) $(CXXFLAGS) tests/test_classifier.cpp core/classifier.o -o $@

# state_checks links the real implementation (not stubs) so the empty-
# manifest paths exercise the actual code. That pulls in shell/ui
# helpers from libfox-common + libcrypto for hash_string.
tests/test_state_checks: tests/test_state_checks.cpp core/state_checks.o core/state_manifest.o core/classifier.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_state_checks.cpp core/state_checks.o core/state_manifest.o core/classifier.o -L$(FOX_COMMON_DIR) -lfox-common -lcrypto -o $@

# conflict_resolve exercises real file-IO (the apply() path); the
# interactive prompt() path is not driven from tests. Links libfox-common
# because the diff invocation goes through sh::run.
tests/test_conflict_resolve: tests/test_conflict_resolve.cpp core/conflict_resolve.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_conflict_resolve.cpp core/conflict_resolve.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

# wizard tests the data types + default_plan (pure logic). Step 9
# adds the interactive run() body, which isn't unit-tested. The link
# pulls classifier + conflict_resolve in because wizard's structs
# embed their types.
tests/test_wizard: tests/test_wizard.cpp core/wizard.o core/classifier.o core/conflict_resolve.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_wizard.cpp core/wizard.o core/classifier.o core/conflict_resolve.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

# install_lock — POSIX flock + lockfile path resolution. No fox-common
# dependency; pure libc plus filesystem.
tests/test_install_lock: tests/test_install_lock.cpp core/install_lock.o
	$(CXX) $(CXXFLAGS) tests/test_install_lock.cpp core/install_lock.o -o $@

clean:
	@rm -f $(BIN) $(CORE_OBJ) $(MODULE_OBJ) $(MAIN_OBJ) tests/test_registry tests/test_state_manifest tests/test_classifier tests/test_state_checks tests/test_conflict_resolve tests/test_wizard tests/test_install_lock

.PHONY: all install clean test
