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
LIB_OBJ := sidecar.o
BIN     := fox-monitor

all: $(LIB) $(BIN)

$(LIB): $(LIB_OBJ)
	ar rcs $@ $^

sidecar.o: sidecar.cpp sidecar.hpp
	$(CXX) $(CXXFLAGS) -c sidecar.cpp -o $@

$(BIN): main.o $(LIB) $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -o $@ main.o -L. -lfox-monitor -L$(FOX_COMMON_DIR) -lfox-common

main.o: main.cpp sidecar.hpp
	$(CXX) $(CXXFLAGS) -I$(FOX_COMMON_DIR) -c main.cpp -o $@

$(FOX_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(FOX_COMMON_DIR)

install: all
	@mkdir -p $(PREFIX)
	@# Atomic-rename pattern — survives ETXTBSY if the binary is in use.
	@install -m 755 $(BIN) $(PREFIX)/$(BIN).new
	@mv $(PREFIX)/$(BIN).new $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(BIN) $(LIB) $(LIB_OBJ) main.o

.PHONY: all install clean
