# src/fox-monitor/Makefile — monitor layout status / reconcile / rotate.
#
# Produces libfox-monitor.a (the reusable monitor library — sidecar
# read/write today, more submodules as reconcile lands) AND the
# fox-monitor binary. fox-install also links libfox-monitor.a so there
# is exactly ONE sidecar implementation across the tree.
#
# Links libfox-common for the shared ui:: / sh:: helpers; the nlohmann
# json.hpp header comes in via the include path (header-only, no link).

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

FOX_COMMON_DIR := ../fox-common
FOX_COMMON_LIB := $(FOX_COMMON_DIR)/libfox-common.a

LIB     := libfox-monitor.a
LIB_OBJ := sidecar.o variants.o rederive.o apply.o
BIN     := fox-monitor

all: $(LIB) $(BIN)

$(LIB): $(LIB_OBJ)
	ar rcs $@ $^

sidecar.o: sidecar.cpp sidecar.hpp
	$(CXX) $(CXXFLAGS) -c sidecar.cpp -o $@

# variants.o pulls in fox-common headers (ui.hpp / shell.hpp); the symbols
# resolve at the final link of each binary that links -lfox-common.
variants.o: variants.cpp variants.hpp $(FOX_COMMON_DIR)/ui.hpp $(FOX_COMMON_DIR)/shell.hpp
	$(CXX) $(CXXFLAGS) -c variants.cpp -o $@

# rederive.o: live hyprctl → Layout. Needs json.hpp (header-only) + shell.hpp.
rederive.o: rederive.cpp rederive.hpp sidecar.hpp $(FOX_COMMON_DIR)/shell.hpp
	$(CXX) $(CXXFLAGS) -c rederive.cpp -o $@

# apply.o: re-apply the CURRENT wallpaper per monitor via awww. ui:: / sh::
# symbols resolve against libfox-common at the final binary link.
apply.o: apply.cpp apply.hpp sidecar.hpp $(FOX_COMMON_DIR)/ui.hpp $(FOX_COMMON_DIR)/shell.hpp
	$(CXX) $(CXXFLAGS) -c apply.cpp -o $@

$(BIN): main.o $(LIB) $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -o $@ main.o -L. -lfox-monitor -L$(FOX_COMMON_DIR) -lfox-common

main.o: main.cpp sidecar.hpp rederive.hpp apply.hpp variants.hpp
	$(CXX) $(CXXFLAGS) -I$(FOX_COMMON_DIR) -c main.cpp -o $@

$(FOX_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(FOX_COMMON_DIR)

install: all
	@mkdir -p $(PREFIX)
	@# Atomic-rename pattern — survives ETXTBSY if the binary is in use.
	@install -m 755 $(BIN) $(PREFIX)/$(BIN).new
	@mv $(PREFIX)/$(BIN).new $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

# ── tests ───────────────────────────────────────────────────────────
# test_variants pins the PURE plan_variants() contract (NATIVE dims, dedupe,
# _portrait/_WxH exclusion, native-match skip, wrong-dims force-regen, orphan
# prune). It only needs the planner symbol from variants.o; the executor's
# ui::/sh:: refs would otherwise want libfox-common, so we link it.
# test_sidecar round-trips fox_monitor::sidecar read/write + byte-format.
# test_rederive pins the PURE from_hyprctl_json() contract (transform-swap,
# portrait/secondary derivation, sticky-primary preserve + first-fallback).
# It links only rederive.o + shell.o (via libfox-common, for the sh:: refs
# rederive.cpp carries even though the pure fn touches none of them).
test: tests/test_variants tests/test_sidecar tests/test_rederive
	@./tests/test_variants
	@./tests/test_sidecar
	@./tests/test_rederive

tests/test_variants: tests/test_variants.cpp variants.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_variants.cpp variants.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

tests/test_sidecar: tests/test_sidecar.cpp $(LIB)
	$(CXX) $(CXXFLAGS) tests/test_sidecar.cpp -L. -lfox-monitor -o $@

tests/test_rederive: tests/test_rederive.cpp rederive.o sidecar.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_rederive.cpp rederive.o sidecar.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

clean:
	@rm -f $(BIN) $(LIB) $(LIB_OBJ) main.o \
	       tests/test_variants tests/test_sidecar tests/test_rederive

.PHONY: all install clean test
