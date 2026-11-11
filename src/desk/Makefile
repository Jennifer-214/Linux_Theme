# src/desk/Makefile — top-level dispatcher binary.
#
# Builds the `fox` entry-point that dispatches `fox <ns> <sub> [args]`
# to the appropriate namespace binary. Namespace registry lives in
# dispatch.def (X-macro expanded by main.cpp).
#
# Each new namespace (desk-ai, desk-sec, ...) adds one line to dispatch.def.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX   ?= $(HOME)/.local/bin

DESK_COMMON_DIR := ../desk-common
DESK_COMMON_LIB := $(DESK_COMMON_DIR)/libdesk-common.a

BIN := desk

all: $(BIN)

$(BIN): main.o $(DESK_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -o $@ main.o -L$(DESK_COMMON_DIR) -ldesk-common

main.o: main.cpp dispatch.def
	$(CXX) $(CXXFLAGS) -I$(DESK_COMMON_DIR) -c main.cpp -o $@

# Ensure libdesk-common.a is built before linking ourselves.
$(DESK_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(DESK_COMMON_DIR)

install: all
	@mkdir -p $(PREFIX)
	@install -m 755 $(BIN) $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

test: $(BIN)
	@bash tests/help_test.sh

clean:
	@rm -f $(BIN) main.o

.PHONY: all install clean test
