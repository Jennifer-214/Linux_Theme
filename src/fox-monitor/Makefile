# src/fox-monitor/Makefile — monitor layout status / reconcile / rotate.
#
# Slice A: read-only `status` + loud stubs. Links libfox-common for the
# shared ui:: / sh:: helpers; the nlohmann json.hpp header comes in via
# the include path (header-only, no link needed).

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

FOX_COMMON_DIR := ../fox-common
FOX_COMMON_LIB := $(FOX_COMMON_DIR)/libfox-common.a

BIN := fox-monitor

all: $(BIN)

$(BIN): main.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -o $@ main.o -L$(FOX_COMMON_DIR) -lfox-common

main.o: main.cpp
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
	@rm -f $(BIN) main.o

.PHONY: all install clean
